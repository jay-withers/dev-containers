# Dev Containers

A catalog of VS Code dev container images for Azure infrastructure development. Images are built from a shared base and published to the GitHub Container Registry, so any repo can reference one directly — no local build required.

## Available images

| Image       | Registry path                                  | Tooling on top of base                                                        |
| ----------- | ---------------------------------------------- | ----------------------------------------------------------------------------- |
| `base`      | `ghcr.io/jay-withers/dev-containers/base`      | Azure CLI, Node.js, PowerShell, Docker CLI, pre-commit, general CLI utilities |
| `terraform` | `ghcr.io/jay-withers/dev-containers/terraform` | + tflint, checkov, terraform-docs, tfenv                                      |
| `k8s`       | `ghcr.io/jay-withers/dev-containers/k8s`       | + kubectl, kubectx, helm, k9s                                                 |

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

## Using Docker from inside a dev container

Every image ships the Docker **client** — `docker`, plus the `buildx` and `compose` plugins — but no daemon. This is "Docker outside of Docker": commands talk to your *host's* Docker daemon, so containers you start are siblings on the host rather than nested inside the dev container. Nothing needs privileged mode.

Two things go in the consuming repo's `devcontainer.json` — bind-mount the host socket, and run the setup helper once per container start:

```json
{
  "image": "ghcr.io/jay-withers/dev-containers/base:latest",
  "mounts": [
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
  ],
  "postStartCommand": "sudo /usr/local/bin/docker-socket-setup"
}
```

The mount alone is not quite enough for the non-root `vscode` user, because who owns the socket depends on the host, and that can only be discovered once it is mounted. `docker-socket-setup` handles both cases:

- **Linux hosts**, where the socket is owned by the host's `docker` group: the image's `docker` group adopts that GID (or, if another group already holds it, that group is used) and `vscode` is added to it.
- **Docker Desktop** (macOS and Windows), where the socket is mounted owned by `root`: no group membership can reach it and loosening its mode would alter permissions on the host's own socket, so socat proxies it to a second, `vscode`-owned socket and `DOCKER_HOST` is pointed there automatically for interactive shells.

It needs root — hence `sudo`, which the `vscode` user has passwordless — and is safe to re-run, which `postStartCommand` does on every start. Skip the hook and the CLI still works as `root` or via `sudo docker ...`.

## Prerequisites (for local use)

- [Docker](https://www.docker.com/get-started/) installed and running
- An `amd64` or `arm64` host — `make build` builds for the host architecture, which BuildKit reports to the Dockerfiles as `TARGETARCH`

## Repository layout

```text
images/
  base/Dockerfile        # shared: ubuntu, Azure CLI, Node.js, PowerShell, Docker CLI, pre-commit, general CLI utilities
  base/docker-socket-setup.sh  # container-start helper that grants non-root access to the mounted Docker socket
  terraform/Dockerfile   # FROM base + tflint, checkov, terraform-docs, tfenv
  k8s/Dockerfile         # FROM base + kubectl, kubectx, helm, k9s
.pre-commit-config.yaml  # pre-commit hooks (+ .gitleaks.toml, commitlint.config.js)
scripts/                 # one-off / scheduled repo admin scripts (GHCR pruning, image scanning)
Makefile                 # setup / lint / build targets (run `make help`)
```

## Tooling versions

All tools are installed from version-pinned URLs and verified at build time against the checksum the upstream project publishes for that version (checkov and pre-commit, which publish no checksum file, are instead verified against the SHA256 digest reported by the GitHub release API). Azure CLI, ble.sh, and the Docker CLI have no upstream checksum, so they stay pinned to a hand-maintained `@sha256:` digest — and because the Azure CLI `.deb` and the Docker CLI tarball differ per architecture, each carries one URL and digest per architecture. In the `terraform` image, the Terraform version is managed by tfenv via a `.terraform-version` file in the consuming repo's workspace root.

Each tool ARG holds the URL of the `arm64` asset, and the install step rewrites that architecture token to match the architecture being built (read from BuildKit's `TARGETARCH`). Upstream naming is not consistent — Node and PowerShell publish `x64`, kubectx publishes `x86_64`, checkov publishes `X86_64`, and the Docker CLI and compose pair `x86_64` with `aarch64` (the only tools that rename the arm64 side as well), where most projects use `amd64` — so those tools map the token explicitly. Keeping the version in a literal URL is what lets Renovate's custom managers find and bump it.

The base image runs `apt-get upgrade` before installing anything, so the packages the upstream base image already ships are patched to whatever Ubuntu currently has. That is deliberately not reproducible — an apt package carries no version pin here, and leaving it unpinned *and* un-upgraded would freeze it at whatever version the upstream base was built with. The URL-pinned tools above are what make the build reproducible where it matters.

It costs roughly 126MB of uncompressed image size: Docker layers are additive, so the upgraded copies of the ~115 packages involved sit on top of the originals in the upstream base's layers instead of replacing them. That is the price of patched apt packages in an image people develop in.

The base image also installs a set of general-purpose CLI utilities from Ubuntu's apt repositories (apt verifies these itself, so they carry no version pin): DNS/network tools (`dig`, `nslookup`, `host`, `ping`, `traceroute`, `nc`, `socat` — the last of which also backs the Docker socket proxy described above), plus `jq`, `wget`, `rsync`, `zip`, `file`, `tree`, `vim`, `nano`, and `less`.

Shell (bash) tab completion is enabled for: Azure CLI, GitHub CLI, Docker, kubectl, helm, terraform-docs, and terraform. The base image also ships [ble.sh](https://github.com/akinomyoga/ble.sh), which gives interactive bash shells Fish-style inline autosuggestions — as you type, the most recent matching command from history appears greyed-out ahead of the cursor; press the right-arrow key to accept it. It is sourced automatically from the `vscode` user's `.bashrc`.

| Tool           | Version      | Image     |
| -------------- | ------------ | --------- |
| Azure CLI      | 2.73.0       | base      |
| GitHub CLI     | 2.96.0       | base      |
| Node.js        | 24.16.0      | base      |
| PowerShell     | 7.6.5        | base      |
| pre-commit     | 4.6.2        | base      |
| Docker CLI     | 29.7.2       | base      |
| docker buildx  | 0.37.0       | base      |
| docker compose | 5.5.0        | base      |
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
| `cd-scan`            | Last stage of `cd-publish`, or manual     | Scans the images just published for known vulnerabilities and reports the findings (see below)       |
| `cd-prune`           | Mondays 08:00 UTC, or run manually        | Prunes old image versions and spent CI PR tags from GHCR (see below)                                 |

## Vulnerability scanning

`cd-scan` runs [Trivy](https://trivy.dev/) via [scripts/scan-images.sh](scripts/scan-images.sh) as the **last stage of `cd-publish`**, against the version that was just published. It scans the multi-arch manifest for both `linux/amd64` and `linux/arm64`, reading each platform's layers straight out of the registry, so both architectures are covered from one runner with nothing emulated and nothing executed.

Scanning at publish time rather than on a timer means every report describes an exact, immutable version tag rather than whatever `latest` pointed at when a schedule fired, and every release is covered — including a mid-week Renovate tool bump, which a weekly scan would not report until the following Monday. Because `cd-weekly` publishes a rebuild every Monday, a report still arrives at least weekly in a week with no merges. `cd-scan` is also callable on its own via `workflow_dispatch` with a `tag` input, to scan any published tag without republishing anything.

It is the final job in the publish run and gates nothing: every image is tagged and pullable before it starts, so a red `scan` job means the report failed, never that the release did.

**It reports; it never fails on a finding.** Nothing here is gated on a CVE, so a disclosure can't block a publish or stall a Renovate auto-merge. That is a deliberate trade: the fix for a finding is a package upgrade or a base refresh, and a red build wouldn't produce either. A scan that *fails to run* does fail the job, because an incomplete report otherwise reads as "nothing found".

The report goes two places:

- the **workflow run summary**, in full
- a **tracked GitHub issue** labelled `vulnerability-report`, which is what reaches your inbox. Each run posts a comment (GitHub emails subscribers on new issues and new comments, but *not* on body edits) and refreshes the issue body so the issue itself always shows the latest run. The first run assigns the issue to the repo owner, which is what subscribes you. Close the issue and the next run opens a fresh one — no secrets, no SMTP configuration.

To get the email, GitHub notifications for **Issues** must be enabled on your account (Settings → Notifications → Subscriptions), which is the default for issues you're assigned to or participating in.

Findings are deduplicated across platforms on (CVE, package) — both architectures install the same apt packages, so an undeduplicated count would double everything — and the report's *Platforms* column shows where each was seen. The detail table lists only **fixable HIGH/CRITICAL** findings — everything else is summarised numerically, because tabling several thousand MEDIUMs makes a report nobody reads. The table is capped at `MAX_ROWS` (200) per image, set above what these images actually carry so a normal run tables everything; the cap exists to stop a pathological result set producing an unreadable report, and the remainder is always reported as a count rather than dropped silently.

### Kernel headers

Ubuntu records every kernel CVE against `linux-libc-dev`, which on the current base accounts for the large majority of HIGH/CRITICAL findings. That package ships header files, not a kernel — a container uses the host's kernel — so none of those findings is reachable in these images. They are counted in their own column and excluded from the others rather than silently dropped. `IGNORE_PKGS` holds the list; set `IGNORE_PKGS=` to fold them back into the headline.

### Reading a finding

Fixable findings in these images come from three places, each with a different fix:

- **apt packages.** The base image runs `apt-get upgrade` before installing anything, so these are patched to whatever Ubuntu currently ships as of the build — the weekly rebuild is what keeps that current. A finding surviving here means Ubuntu has published no fix, or the fix needs a package added or removed (`upgrade` won't do either; see the note in [images/base/Dockerfile](images/base/Dockerfile)).
- **libraries vendored inside the pinned tool downloads** — Python packages inside the Azure CLI, npm packages inside Node, the Go standard library compiled into `gh`, `tflint`, and friends. These clear when Renovate bumps that tool's pinned URL.
- **kernel headers**, as above — nothing to fix.

Run a scan locally (needs `jq`, plus either `trivy` on `PATH` or Docker — the script falls back to running Trivy from a container):

```sh
make scan-images                                  # report on :latest for both architectures
make scan-images TAG=v1.2.3                       # report on a specific published version
make scan-images PLATFORMS=linux/arm64            # one architecture only
./scripts/scan-images.sh > report.md              # report to a file, progress to the terminal
IGNORE_PKGS= MAX_ROWS=500 make scan-images        # everything, kernel headers included
```

The script takes `REPO`, `TAG`, `PLATFORMS`, `IMAGES`, `IGNORE_PKGS`, `MAX_ROWS`, and `TRIVY_IMAGE` as environment overrides — see the header of [scripts/scan-images.sh](scripts/scan-images.sh). Images are discovered from the `images/` directory, so a new image is scanned with no change here. The workflow takes the image `tag` as a `workflow_dispatch` input.

Trivy itself is intentionally installed at `latest` rather than pinned: no Renovate manager in this repo bumps an action's version input, so a pin would go stale and quietly stop detecting new CVEs. Each report records the exact Trivy version that produced it.

## Registry retention

Because `cd-weekly` mints a new patch version every Monday, each package would otherwise gain a version a week indefinitely. `cd-prune` runs two hours after that publish and prunes the backlog by calling [scripts/prune-packages.sh](scripts/prune-packages.sh), which keeps:

- the **10 most recent release versions** (tags matching `vMAJOR.MINOR.PATCH`) of every image, ordered by semver
- the throwaway **`pr-<run_id>-<arch>` tags** that `ci-container-build` pushes, until they are **7 days old**. They are only needed for the minutes between one CI run's base and leaf jobs, but the age floor means a prune landing mid-run can't pull the base image out from under a leaf job still building `FROM` it
- **every version carrying any other tag** — `latest`, anything applied by hand. Unrecognised tags are never touched
- the **untagged per-architecture child manifests** of each kept version

Everything else goes: release versions past the 10 most recent, expired PR tags, and untagged manifests that no kept version references (the per-architecture children of the versions being deleted, and leftovers from publish runs that pushed by digest and then failed before merging a manifest).

A version is only deleted when *every* tag on it is expendable — GHCR can delete a version but not an individual tag, so a PR build that happens to reproduce a release digest (both tags landing on one version) keeps that version alive until the release itself ages out.

That last point is why this is a script rather than an off-the-shelf "delete untagged versions" action. `cd-publish` pushes each architecture by digest with no tag, so every published version has untagged children in GHCR that its tagged manifest points at — deleting untagged versions indiscriminately breaks multi-arch manifests that are still tagged and in use. The script reads each kept version's children back out of the registry and excludes them, and if any of those manifests can't be read it skips untagged pruning for that image and exits non-zero rather than guessing.

Preview a prune, or run one by hand:

```sh
make prune-packages                            # dry run (the default): report what would be deleted
make prune-packages DRY_RUN=false              # actually delete
make prune-packages KEEP=20 DRY_RUN=false      # keep more history
make prune-packages PR_MAX_AGE_DAYS=1          # sweep PR tags sooner
```

The workflow takes the same `keep`, `pr_max_age_days`, and `dry_run` values as `workflow_dispatch` inputs. Deletion uses the repo's `GITHUB_TOKEN`, which is sufficient for packages scoped to this repo; if that ever stops being true, add a `PACKAGES_TOKEN` secret (a PAT with `delete:packages`) and the workflow uses it instead. Note that GitHub refuses to delete any version of a **public** package once it has more than 5,000 downloads — that shows up as a delete failure the job reports and fails on, and can only be resolved via GitHub support.

## Dependency updates

[Renovate](https://docs.renovatebot.com/) is configured in [renovate.json](renovate.json) to keep pinned versions up to date automatically. The config extends two shared [`jay-withers/template-renovate`](https://github.com/jay-withers/template-renovate) presets — the umbrella preset (auto-merge policy, weekly schedule, ecosystem grouping/labels) and the `:dev-container` preset (custom managers for the version-pinned Dockerfile tool ARGs). It raises PRs for:

- GitHub Actions (`uses:` pins in workflows)
- Pre-commit hook revisions (`.pre-commit-config.yaml`)
- Dockerfile `FROM` base images
- Tool versions in Dockerfile ARGs across `images/base`, `images/terraform`, and `images/k8s`

Renovate will auto-approve and auto-merge PRs (squash) once the `ci-pre-commit` and `ci-container-build` workflows pass.

For platform (GitHub-native) auto-merge to engage, the repository must have **Allow auto-merge** enabled and a branch-protection rule on `main` requiring the CI status check. Without a protection rule, GitHub refuses to enable auto-merge and PRs sit until Renovate's next scheduled run. Both are configured for this repo via [jay-withers/github-repos](https://github.com/jay-withers/github-repos)'s Terraform root module (`terraform/ruleset.tf`), which manages branch protection and repo settings across every jay-withers repo.

To enable it, install the [Renovate GitHub App](https://github.com/apps/renovate) on the repository.
