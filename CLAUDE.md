# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Claude instructions

When you add, remove, or significantly change a feature, command, or configuration option, update README.md to reflect it before marking the task complete.

## What this repo is

A catalog of VS Code dev container images for Azure infrastructure development. Each image is defined under `images/<name>/Dockerfile`, built and published to the GitHub Container Registry (`ghcr.io/jay-withers/dev-containers/<name>`), and consumed by other repos via an `image:` reference in their `.devcontainer/devcontainer.json`. There is no application code — the primary deliverable is the set of container images.

Common tasks are wrapped in the `Makefile` (run `make help` to list them):

```sh
make setup   # install the pre-commit git hooks
make lint    # run all pre-commit hooks against every file (the standard way to validate changes)
make build   # build base, terraform, and k8s images locally
```

Individual image builds are also available (`make build-base`, `make build-terraform`, `make build-k8s`). The `lint`/`setup` targets wrap `pre-commit`, which picks up `.pre-commit-config.yaml` from the repo root automatically.

## Architecture

### Images

Images form a base + specialisation hierarchy under `images/`:

- **`images/base/Dockerfile`** — builds from `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`. Installs the tooling common to every image: Azure CLI, GitHub CLI, Node.js, pre-commit. Tools are installed from version-pinned URLs and verified at build time against the checksum the upstream project publishes for that version (checkov against the GitHub release API digest); Azure CLI and ble.sh, which publish no checksum, keep a hand-maintained `@sha256:` digest suffix.
- **`images/terraform/Dockerfile`** — `FROM` the base image (via the `BASE_IMAGE` build arg, defaulting to the published `:latest`). Adds TFLint, Checkov, terraform-docs, and tfenv (which manages the Terraform version via `.terraform-version` in the consuming repo's workspace).
- **`images/k8s/Dockerfile`** — `FROM` the base image. Adds kubectl, kubectx, helm, and k9s.

Specialised images switch to `USER root` to install, then back to `USER vscode`. To add a new image, create `images/<name>/Dockerfile` `FROM` the base and add it to the `leaves` and `leaves-merge` matrices in `cd-publish.yml` and the build/smoke-test steps in `ci-container-build.yml`.

### Architecture handling

Every image is published as a multi-arch manifest covering `linux/amd64` and `linux/arm64`. The tool downloads are architecture-specific, so each `ARG` holds the URL of the **arm64** asset and the install step rewrites that token to match BuildKit's `TARGETARCH` before downloading. Upstream naming is inconsistent — Node uses `x64`, kubectx uses `x86_64`, checkov uses `X86_64`, and everything else uses `amd64` — so those three map the token explicitly via a `case`; the rest substitute `TARGETARCH` directly. Anything other than `amd64`/`arm64` fails the build loudly rather than silently downloading the wrong binary.

Keeping the version in a literal URL (rather than composing it from a separate version ARG) is deliberate: Renovate's custom managers in the shared preset regex-match these lines, and they capture the version from the URL path ahead of the architecture token. When adding a tool, check whether its x86-64 asset is named `amd64` and add a mapping if not.

### Pre-commit configuration

This repo's own hooks live in **`.pre-commit-config.yaml`** at the repo root — secret scanning, workflow/config linting, commit-message validation, plus the standard whitespace/format hooks. Hook revisions are frozen with a comment showing the upstream tag; Renovate keeps these updated automatically.

### Dependency pinning and updates

Tool versions are declared as `ARG` values in each image's Dockerfile as full download URLs with `@sha256:` digests appended. **`renovate.json`** extends two shared [`jay-withers/template-renovate`](https://github.com/jay-withers/template-renovate) presets: the umbrella preset (auto-merge policy, weekly schedule, ecosystem grouping/labels, and handling of GitHub Actions pins, Dockerfile `FROM` base images, and pre-commit hook revisions) and the `:dev-container` preset, whose regex custom managers parse the tool ARGs in each image Dockerfile and raise PRs — grouped into a single "dev container tools" PR — when new releases are available. Because the custom managers live in the shared preset, adding a new pinned tool ARG here means adding a manager to [`template-renovate/dev-container.json`](https://github.com/jay-withers/template-renovate/blob/main/dev-container.json), not to this repo. All Renovate PRs are auto-approved and auto-merged (squash) once CI passes.

### Commit messages

Commits must follow [Conventional Commits](https://www.conventionalcommits.org/). The commitlint hook (`commitlint.config.js`) enforces this at the `commit-msg` stage. The `no-commit-to-branch` hook blocks direct commits to `main`.

### CI

- **`.github/workflows/ci-pre-commit.yml`** — runs on PRs to `main`. Installs tools then runs `pre-commit run --all-files`. The `no-commit-to-branch` hook is skipped in CI via `SKIP=no-commit-to-branch`.
- **`.github/workflows/ci-container-build.yml`** — runs on PRs that change `images/**`. Builds the base image for `linux/amd64` and `linux/arm64`, each on a native runner of that architecture (`ubuntu-24.04` and `ubuntu-24.04-arm`), then builds the terraform and k8s images (`FROM` the matching per-arch base) and smoke-tests every tool on both architectures. Because the leaf jobs run on different runners than the base jobs, the base is pushed to GHCR under a throwaway `pr-<run_id>-<arch>` tag; no release tag is published.
- **`.github/workflows/cd-tag.yml`** — runs on merge to `main`. Bumps the semver tag, then calls `cd-publish.yml` (reusable workflow) for the new version. Guarded so publish only runs when a tag was actually created.
- **`.github/workflows/cd-publish.yml`** — reusable (`workflow_call`) and manual (`workflow_dispatch`). Checks out the given tag, then runs four job stages: `base` builds each architecture on its native runner and pushes **by digest** with no tag; `base-merge` combines those digests into one multi-arch manifest tagged with the version and `latest`; `leaves` does the same per architecture for `terraform` and `k8s`, referencing the freshly merged multi-arch base at the same version (so each runner resolves its own architecture); `leaves-merge` publishes a multi-arch manifest per leaf image. Per-architecture digests travel between jobs as artifacts, since that is the only way to pass a value out of one matrix leg. Re-runnable against an existing tag without minting a new version.
