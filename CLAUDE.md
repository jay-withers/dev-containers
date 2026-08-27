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

Two scheduled maintenance tasks are also wrapped: `make prune-packages` (GHCR retention, dry-runs by default) and `make scan-images` (vulnerability report on the published images).

Individual image builds are also available (`make build-base`, `make build-terraform`, `make build-k8s`). The `lint`/`setup` targets wrap `pre-commit`, which picks up `.pre-commit-config.yaml` from the repo root automatically.

## Architecture

### Images

Images form a base + specialisation hierarchy under `images/`:

- **`images/base/Dockerfile`** — builds from `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`. Runs `apt-get upgrade` first, so the packages the upstream base already ships get security patches (nothing pins an apt version, so without it they stay frozen at whatever the upstream build had); then installs the tooling common to every image: Azure CLI, GitHub CLI, Node.js, PowerShell, pre-commit. Tools are installed from version-pinned URLs and verified at build time against the checksum the upstream project publishes for that version (checkov and pre-commit, which publish no checksum file, are instead verified against the GitHub release API digest); Azure CLI and ble.sh, which publish no checksum, keep a hand-maintained `@sha256:` digest suffix.
- **`images/terraform/Dockerfile`** — `FROM` the base image (via the `BASE_IMAGE` build arg, defaulting to the published `:latest`). Adds TFLint, Checkov, terraform-docs, and tfenv (which manages the Terraform version via `.terraform-version` in the consuming repo's workspace).
- **`images/k8s/Dockerfile`** — `FROM` the base image. Adds kubectl, kubectx, helm, and k9s.

Specialised images switch to `USER root` to install, then back to `USER vscode`. To add a new image, create `images/<name>/Dockerfile` `FROM` the base and add it to the `leaves` and `leaves-merge` matrices in `cd-publish.yml` and the build/smoke-test steps in `ci-container-build.yml`.

### Architecture handling

Every image is published as a multi-arch manifest covering `linux/amd64` and `linux/arm64`. The tool downloads are architecture-specific, so each `ARG` holds the URL of the **arm64** asset and the install step rewrites that token to match BuildKit's `TARGETARCH` before downloading. Upstream naming is inconsistent — Node and PowerShell use `x64`, kubectx uses `x86_64`, checkov uses `X86_64`, and everything else uses `amd64` — so those map the token explicitly via a `case`; the rest substitute `TARGETARCH` directly. Anything other than `amd64`/`arm64` fails the build loudly rather than silently downloading the wrong binary.

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
- **`.github/workflows/cd-publish.yml`** — reusable (`workflow_call`) and manual (`workflow_dispatch`). Checks out the given tag, then runs five job stages: `base` builds each architecture on its native runner and pushes **by digest** with no tag; `base-merge` combines those digests into one multi-arch manifest tagged with the version and `latest`; `leaves` does the same per architecture for `terraform` and `k8s`, referencing the freshly merged multi-arch base at the same version (so each runner resolves its own architecture); `leaves-merge` publishes a multi-arch manifest per leaf image; finally `scan` calls `cd-scan.yml` for the version just published. Per-architecture digests travel between jobs as artifacts, since that is the only way to pass a value out of one matrix leg. Re-runnable against an existing tag without minting a new version. The `scan` job gates nothing — everything is published before it starts, so a failure there is a failed report, not a failed release.
- **`.github/workflows/cd-scan.yml`** — reusable (`workflow_call`, invoked as the last job of `cd-publish` against the version just published) and manual (`workflow_dispatch`, to scan any published tag). Scanning at publish time rather than on a schedule ties each report to an exact immutable tag instead of whatever `latest` pointed at when a timer fired, and covers mid-week releases; `cd-weekly` still guarantees a report at least weekly. Because a nested reusable workflow can only narrow the permissions its caller grants, `issues: write` has to be declared on the `publish` job in **both** `cd-tag.yml` and `cd-weekly.yml`, not just here. Runs `scripts/scan-images.sh`, which scans the published images with Trivy for both platforms (read from the registry — nothing is executed or emulated) and emits a markdown report. **Report-only: a finding never fails the job**, since the fix for a CVE is a package upgrade or a base refresh, not a red build; a scan that fails to *run* does fail, so an incomplete report can't read as "nothing found". The report goes to the run summary and to a tracked issue labelled `vulnerability-report` — each run comments (which is what emails the owner; a body edit sends no notification) and refreshes the body. Findings are deduplicated across platforms on (CVE, package), and `linux-libc-dev` findings are counted separately rather than in the headline, because kernel headers ship no kernel and aren't reachable in a container. Images are discovered from `images/`, so a new image needs no change here.
- **`.github/workflows/cd-prune.yml`** — Mondays 08:00 UTC (two hours after `cd-weekly` publishes) and manual. Runs `scripts/prune-packages.sh`, which keeps the 10 most recent release versions (`vX.Y.Z` tags) of each image, the CI `pr-<run_id>-<arch>` tags until they are 7 days old (`PR_MAX_AGE_DAYS` — an age floor so a prune landing mid-run can't delete a base image a leaf job is still building `FROM`), and every version with any other tag (`latest`, hand-applied). It then deletes older releases, expired PR tags, and untagged manifests that no kept version references. A version goes only when *every* tag on it is expendable, since GHCR deletes versions rather than individual tags. It reads each kept version's child digests back out of the registry first, because `cd-publish` pushes per-architecture images untagged — a blanket "delete untagged" sweep would break live multi-arch manifests. Images are discovered from the `images/` directory, so a new image needs no change here. `DRY_RUN=true` reports without deleting; `make prune-packages` wraps it and dry-runs by default.
