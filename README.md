# Dev Containers

A catalog of VS Code dev container images for Azure infrastructure development. Images are built from a shared base and published to the GitHub Container Registry, so any repo can reference one directly — no local build required.

## Available images

| Image       | Registry path                                  | Tooling on top of base                                |
| ----------- | ---------------------------------------------- | ----------------------------------------------------- |
| `base`      | `ghcr.io/jay-withers/dev-containers/base`      | Azure CLI, Node.js, pre-commit, general CLI utilities |
| `terraform` | `ghcr.io/jay-withers/dev-containers/terraform` | + tflint, checkov, terraform-docs, tfenv              |
| `k8s`       | `ghcr.io/jay-withers/dev-containers/k8s`       | + kubectl, kubectx, helm, k9s                         |

Each specialised image is built `FROM` the base image, so common tooling stays in one place.

Every image is published as a multi-arch manifest covering `linux/amd64` and `linux/arm64`, so the same tag works on Apple Silicon, x86 laptops, and GitHub Codespaces alike — Docker resolves the right architecture automatically.

## Using an image in another repo

Add a `.devcontainer/devcontainer.json` that references the published image:

```json
{
  "image": "ghcr.io/jay-withers/dev-containers/terraform:latest",
  "customizations": {
    "vscode": {
      "extensions": []
    }
  }
}
```

For the `terraform` image, pin a Terraform version by adding a `.terraform-version` file to your workspace root; install it with `tfenv install` (e.g. from a `postCreateCommand`).

To pin to a specific image version rather than `latest`, use a semver tag:

```json
"image": "ghcr.io/jay-withers/dev-containers/terraform:v1.2.3"
```

## Prerequisites (for local use)

- [Docker](https://www.docker.com/get-started/) installed and running
- An `amd64` or `arm64` host — `make build` builds for the host architecture, which BuildKit reports to the Dockerfiles as `TARGETARCH`

## Repository layout

```text
images/
  base/Dockerfile        # shared: ubuntu, Azure CLI, Node.js, pre-commit, general CLI utilities
  terraform/Dockerfile   # FROM base + tflint, checkov, terraform-docs, tfenv
  k8s/Dockerfile         # FROM base + kubectl, kubectx, helm, k9s
.pre-commit-config.yaml  # pre-commit hooks (+ .gitleaks.toml, commitlint.config.js)
Makefile                 # setup / lint / build targets (run `make help`)
```

## Tooling versions

All tools are installed from version-pinned URLs and verified at build time against the checksum the upstream project publishes for that version (checkov, which publishes no checksum file, is verified against the SHA256 digest reported by the GitHub release API). Azure CLI and ble.sh have no upstream checksum, so they stay pinned to a hand-maintained `@sha256:` digest — and because the Azure CLI `.deb` differs per architecture, it carries one URL and digest per architecture. In the `terraform` image, the Terraform version is managed by tfenv via a `.terraform-version` file in the consuming repo's workspace root.

Each tool ARG holds the URL of the `arm64` asset, and the install step rewrites that architecture token to match the architecture being built (read from BuildKit's `TARGETARCH`). Upstream naming is not consistent — Node publishes `x64`, kubectx publishes `x86_64`, and checkov publishes `X86_64`, where most projects use `amd64` — so those tools map the token explicitly. Keeping the version in a literal URL is what lets Renovate's custom managers find and bump it.

The base image also installs a set of general-purpose CLI utilities from Ubuntu's apt repositories (apt verifies these itself, so they carry no version pin): DNS/network tools (`dig`, `nslookup`, `host`, `ping`, `traceroute`, `nc`), plus `jq`, `wget`, `rsync`, `zip`, `file`, `tree`, `vim`, `nano`, and `less`.

Shell (bash) tab completion is enabled for: Azure CLI, GitHub CLI, kubectl, helm, terraform-docs, and terraform. The base image also ships [ble.sh](https://github.com/akinomyoga/ble.sh), which gives interactive bash shells Fish-style inline autosuggestions — as you type, the most recent matching command from history appears greyed-out ahead of the cursor; press the right-arrow key to accept it. It is sourced automatically from the `vscode` user's `.bashrc`.

| Tool           | Version      | Image     |
| -------------- | ------------ | --------- |
| Azure CLI      | 2.73.0       | base      |
| GitHub CLI     | 2.96.0       | base      |
| Node.js        | 24.16.0      | base      |
| pre-commit     | 3.7.1        | base      |
| ble.sh         | 0.4.0-devel3 | base      |
| TFLint         | 0.61.0       | terraform |
| Checkov        | 3.2.529      | terraform |
| terraform-docs | 0.24.0       | terraform |
| tfenv          | latest       | terraform |
| kubectl        | 1.36.2       | k8s       |
| helm           | 4.2.1        | k8s       |
| k9s            | 0.51.0       | k8s       |
| kubectx        | 0.11.0       | k8s       |

## VS Code extensions

Recommended extensions for working on the images:

| Extension                          | Purpose                          |
| ---------------------------------- | -------------------------------- |
| `ms-azuretools.vscode-docker`      | Dockerfile authoring and linting |
| `github.vscode-github-actions`     | GitHub Actions workflow support  |
| `redhat.vscode-yaml`               | YAML language support            |
| `timonwong.shellcheck`             | Shell script linting             |
| `DavidAnson.vscode-markdownlint`   | Markdown linting                 |
| `eamodio.gitlens`                  | Enhanced git tooling             |
| `anthropic.claude-code`            | Claude AI assistant              |

## Pre-commit hooks

This repo's own hooks (defined in [.pre-commit-config.yaml](.pre-commit-config.yaml)) run on every commit:

| Hook                   | What it checks                                                                                |
| ---------------------- | --------------------------------------------------------------------------------------------- |
| `gitleaks`             | Secret scanning                                                                               |
| `actionlint`           | GitHub Actions workflow linting                                                               |
| `check-renovate`       | Renovate config validity                                                                      |
| `commitlint`           | Conventional commit message format (commit-msg stage)                                         |
| Standard hooks         | Trailing whitespace, EOF newline, YAML/JSON validity, merge conflicts, large files            |

Install the hooks and run them manually via the [Makefile](Makefile):

```sh
make setup   # install the pre-commit git hooks
make lint    # run all hooks against every file
```

## CI

| Workflow             | When it runs                              | What it does                                                                                         |
| -------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `ci-pre-commit`      | Every PR to `main`                        | Installs all tools and runs `pre-commit run --all-files` to validate hooks                           |
| `ci-container-build` | PRs that change `images/**`               | Builds base, terraform, and k8s for `linux/amd64` and `linux/arm64` on native runners, then smoke-tests each tool on each architecture |
| `cd-tag`             | Every merge to `main`                     | Bumps the semver tag and cuts a GitHub release via the shared template, then calls `cd-publish`      |
| `cd-publish`         | Called by `cd-tag`/`cd-weekly`, or manual | Checks out the tag, builds each image per architecture on a native runner, and merges the digests into one multi-arch manifest per image, published as that version and `latest` |
| `cd-weekly`          | Mondays 06:00 UTC, or run manually        | Bumps the patch version from the latest release and publishes it (new tag + `latest`) for OS patches |

## Dependency updates

[Renovate](https://docs.renovatebot.com/) is configured in [renovate.json](renovate.json) to keep pinned versions up to date automatically. The config extends two shared [`jay-withers/template-renovate`](https://github.com/jay-withers/template-renovate) presets — the umbrella preset (auto-merge policy, weekly schedule, ecosystem grouping/labels) and the `:dev-container` preset (custom managers for the version-pinned Dockerfile tool ARGs). It raises PRs for:

- GitHub Actions (`uses:` pins in workflows)
- Pre-commit hook revisions (`.pre-commit-config.yaml`)
- Dockerfile `FROM` base images
- Tool versions in Dockerfile ARGs across `images/base`, `images/terraform`, and `images/k8s`

Renovate will auto-approve and auto-merge PRs (squash) once the `ci-pre-commit` and `ci-container-build` workflows pass.

For platform (GitHub-native) auto-merge to engage, the repository must have **Allow auto-merge** enabled and a branch-protection rule on `main` requiring the CI status check. Without a protection rule, GitHub refuses to enable auto-merge and PRs sit until Renovate's next scheduled run.

Configure both in one step with `make protect-branch` (wraps [scripts/protect-branch.sh](scripts/protect-branch.sh)). It requires a `gh` CLI authenticated with admin rights on the repo, and it: enables repository auto-merge and delete-branch-on-merge; clears any existing rulesets; then creates a ruleset requiring the given status checks (plus, where applicable, PR approval), while letting the repo admin and the Renovate app bypass both. The required-review count defaults to 1 on organisation-owned repos but **0 on user-owned repos** — GitHub silently ignores ruleset bypass actors on personal repos, so requiring a review there would block Renovate's own PRs forever (status checks and the direct-push block still apply either way). Override the branch and required checks via `make protect-branch BRANCH=main CHECKS="pre-commit / Pre-commit"` (checks are newline-separated when passing more than one), or the repo/approval count via the `REPO`/`APPROVALS_REQUIRED` env vars — see the script header.

To enable it, install the [Renovate GitHub App](https://github.com/apps/renovate) on the repository.
