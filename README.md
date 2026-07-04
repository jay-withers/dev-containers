# Dev Containers

A catalog of VS Code dev container images for Azure infrastructure development. Images are built from a shared base and published to the GitHub Container Registry, so any repo can reference one directly — no local build required.

## Available images

| Image       | Registry path                                      | Tooling on top of base                       |
| ----------- | -------------------------------------------------- | -------------------------------------------- |
| `base`      | `ghcr.io/jay-withers/dev-container/base`           | Azure CLI, Node.js, pre-commit               |
| `terraform` | `ghcr.io/jay-withers/dev-container/terraform`      | + tflint, checkov, terraform-docs, tfenv     |
| `k8s`       | `ghcr.io/jay-withers/dev-container/k8s`            | + kubectl, kubectx, helm, k9s                |

Each specialised image is built `FROM` the base image, so common tooling stays in one place.

## Using an image in another repo

Add a `.devcontainer/devcontainer.json` that references the published image:

```json
{
  "image": "ghcr.io/jay-withers/dev-container/terraform:latest",
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
"image": "ghcr.io/jay-withers/dev-container/terraform:v1.2.3"
```

## Prerequisites (for local use)

- [Docker](https://www.docker.com/get-started/) installed and running
- An `arm64` host — all images pin `arm64` binaries and CI only builds `linux/arm64`, so `make build` will fail on an `amd64` machine

## Repository layout

```text
images/
  base/Dockerfile        # shared: ubuntu, Azure CLI, Node.js, pre-commit
  terraform/Dockerfile   # FROM base + tflint, checkov, terraform-docs, tfenv
  k8s/Dockerfile         # FROM base + kubectl, kubectx, helm, k9s
.pre-commit-config.yaml  # pre-commit hooks (+ .gitleaks.toml, commitlint.config.js)
Makefile                 # setup / lint / build targets (run `make help`)
```

## Tooling versions

All tools are installed from version-pinned URLs and verified at build time against the checksum the upstream project publishes for that version (checkov, which publishes no checksum file, is verified against the SHA256 digest reported by the GitHub release API). Azure CLI and kubectx have no upstream checksum, so they stay pinned to a hand-maintained `@sha256:` digest. In the `terraform` image, the Terraform version is managed by tfenv via a `.terraform-version` file in the consuming repo's workspace root.

Shell (bash) tab completion is enabled for: Azure CLI, kubectl, helm, terraform-docs, and terraform.

| Tool           | Version | Image     |
| -------------- | ------- | --------- |
| Azure CLI      | 2.73.0  | base      |
| Node.js        | 24.16.0 | base      |
| pre-commit     | 3.7.1   | base      |
| TFLint         | 0.61.0  | terraform |
| Checkov        | 3.2.529 | terraform |
| terraform-docs | 0.24.0  | terraform |
| tfenv          | latest  | terraform |
| kubectl        | 1.36.2  | k8s       |
| helm           | 4.2.1   | k8s       |
| k9s            | 0.51.0  | k8s       |
| kubectx        | 0.11.0  | k8s       |

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
| `ci-container-build` | PRs that change `images/**`               | Builds base, terraform, and k8s images for `linux/arm64` via QEMU and smoke-tests each tool          |
| `cd-tag`             | Every merge to `main`                     | Bumps the semver tag, then calls `cd-publish` for the new version                                    |
| `cd-publish`         | Called by `cd-tag`, or run manually       | Checks out the tag and builds/publishes every image to GHCR as that version and `latest`             |

## Dependency updates

[Renovate](https://docs.renovatebot.com/) is configured in [renovate.json](renovate.json) to keep pinned versions up to date automatically. It raises PRs for:

- GitHub Actions (`uses:` pins in workflows)
- Pre-commit hook revisions (`.pre-commit-config.yaml`)
- Dockerfile `FROM` base images
- Tool versions in Dockerfile ARGs across `images/base`, `images/terraform`, and `images/k8s`

Renovate will auto-approve and auto-merge PRs (squash) once the `ci-pre-commit` and `ci-container-build` workflows pass.

For platform (GitHub-native) auto-merge to engage, the repository must have **Allow auto-merge** enabled and a branch-protection rule on `main` that requires at least the `pre-commit` and `base` status checks. Without a protection rule, GitHub refuses to enable auto-merge and PRs sit until Renovate's next scheduled run.

To enable it, install the [Renovate GitHub App](https://github.com/apps/renovate) on the repository.
