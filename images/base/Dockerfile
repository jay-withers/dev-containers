FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:d94c97dd9cacf183d0a6fd12a8e87b526e9e928307674ae9c94139139c0c6eae

# Shared base image for all dev containers in this repo.
# Specialised images (terraform, k8s, ...) build FROM this.

# A UTF-8 locale keeps interactive tooling (notably ble.sh, below) happy and
# ensures correct handling of non-ASCII output. C.UTF-8 needs no locale-gen.
ENV LANG=C.UTF-8

# Set automatically by BuildKit to the architecture being built for (amd64 or
# arm64). The downloads below are architecture-specific: each URL is written
# with the arm64 asset name, and the install step rewrites that token to
# whatever the upstream project calls the architecture being built. Keeping the
# version in a literal URL is what lets Renovate's custom managers find it.
ARG TARGETARCH

# azure-cli is not tracked by Renovate (no upstream checksum file), so it stays
# pinned to a specific @sha256: digest that is bumped by hand. The .deb differs
# per architecture, so each architecture carries its own URL and digest.
ARG AZURE_CLI_URL_AMD64="https://packages.microsoft.com/repos/azure-cli/pool/main/a/azure-cli/azure-cli_2.73.0-1~noble_amd64.deb@sha256:26b28de55fbc8a397af9bcb0f44c15615943cce0675ae40095bc68bd66acdf6b"
ARG AZURE_CLI_URL_ARM64="https://packages.microsoft.com/repos/azure-cli/pool/main/a/azure-cli/azure-cli_2.73.0-1~noble_arm64.deb@sha256:6af9009a39895ba396e92d5138824091e95f9bd797422db2fe9564a0cf4a35f4"
# ble.sh (interactive-shell inline autosuggestions) publishes no checksum file
# either, so like azure-cli it stays pinned to a hand-maintained @sha256: digest.
# It ships as a single architecture-independent source tarball.
ARG BLESH_URL="https://github.com/akinomyoga/ble.sh/releases/download/v0.4.0-devel3/ble-0.4.0-devel3.tar.xz@sha256:c8612ee612bc6b10dbfd6e85c6cbdfd7caf152a12d1f9de22ea0a9d735b3080c"
# The Docker CLI comes from Docker's own static-binary download server, which
# publishes no checksum file and has no release API to query, so — like
# azure-cli — each architecture carries a hand-maintained @sha256: digest and
# is not tracked by Renovate. The tarball bundles the whole engine; only the
# `docker` client is installed (see the install step below).
ARG DOCKER_CLI_URL_AMD64="https://download.docker.com/linux/static/stable/x86_64/docker-29.7.2.tgz@sha256:803d433f226db4776e1768fd319fc6c6e4935a456acf84fcc0080818b854bc8f"
ARG DOCKER_CLI_URL_ARM64="https://download.docker.com/linux/static/stable/aarch64/docker-29.7.2.tgz@sha256:43d143448adf2c2787704e7d7704fd6d62d367a54c5edaef0a3f75509cb0938d"
# Renovate bumps the version tag in these URLs; each download is verified at
# build time against the checksum the upstream project publishes for that version.
ARG BUILDX_URL="https://github.com/docker/buildx/releases/download/v0.37.0/buildx-v0.37.0.linux-arm64"
ARG COMPOSE_URL="https://github.com/docker/compose/releases/download/v5.5.0/docker-compose-linux-aarch64"
ARG GH_URL="https://github.com/cli/cli/releases/download/v2.98.0/gh_2.98.0_linux_arm64.tar.gz"
ARG NODE_URL="https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-arm64.tar.xz"
ARG PWSH_URL="https://github.com/PowerShell/PowerShell/releases/download/v7.6.5/powershell-7.6.5-linux-arm64.tar.gz"
# pre-commit ships a single architecture-independent .pyz zipapp.
ARG PRE_COMMIT_URL="https://github.com/pre-commit/pre-commit/releases/download/v4.6.2/pre-commit-4.6.2.pyz"

# Base dependencies and general-purpose CLI tools.
# These come from Ubuntu's signed apt repositories, so apt verifies integrity
# itself — no hand-pinned checksums needed (unlike the URL-based tools below).
#
# The upgrade is what patches the packages the upstream base image already
# ships. Nothing here pins an apt version, so without it those packages sit at
# whatever version Microsoft's last build of the base had, however many security
# advisories have landed since — installing alongside them doesn't move them.
# That trades byte-identical rebuilds of a given commit for patched packages,
# which for a dev container is the right way round; the URL-pinned tools below
# are what keep the build reproducible where it matters.
#
# `upgrade` rather than `dist-upgrade`: it never removes a package or pulls in a
# new one to satisfy a changed dependency. Anything held back for that reason
# stays visible in the cd-scan report rather than being silently resolved by
# uninstalling something.
#
# It costs image size: layers are additive, so the upgraded copies land on top
# of the originals in the base image's own layers rather than replacing them —
# measured at ~126MB uncompressed for the ~115 packages upgraded. That buys
# patched apt packages, which for an image people develop in is worth it.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        bash-completion curl unzip xz-utils python3 ca-certificates \
        bind9-dnsutils iputils-ping traceroute netcat-openbsd socat \
        jq wget rsync zip file tree \
        vim nano less \
    && rm -rf /var/lib/apt/lists/*

# azure-cli — verified against its hand-pinned SHA256 digest
RUN case "${TARGETARCH}" in \
        amd64) SPEC="${AZURE_CLI_URL_AMD64}" ;; \
        arm64) SPEC="${AZURE_CLI_URL_ARM64}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="${SPEC%@sha256:*}" \
    && SHA="${SPEC##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/azure-cli.deb \
    && (cd /tmp && echo "${SHA}  azure-cli.deb" | sha256sum -c) \
    && apt-get update && apt-get install -y --no-install-recommends /tmp/azure-cli.deb \
    && rm /tmp/azure-cli.deb \
    && rm -rf /var/lib/apt/lists/* \
    && az --version

# pre-commit — no upstream checksum file (dropped after v4.4.0), so verify
# against the sha256 digest the GitHub API reports for the release asset. The
# API call is authenticated when a gh_token secret is mounted (CI) to avoid
# unauthenticated rate limits, and falls back to an anonymous request
# otherwise (local builds).
RUN --mount=type=secret,id=gh_token \
    FILE="${PRE_COMMIT_URL##*/}"; \
    TAG="${PRE_COMMIT_URL#*/download/}"; TAG="${TAG%%/*}"; \
    API="https://api.github.com/repos/pre-commit/pre-commit/releases/tags/${TAG}"; \
    TOKEN="$(cat /run/secrets/gh_token 2>/dev/null || true)"; \
    curl -fsSL "${PRE_COMMIT_URL}" -o "/tmp/${FILE}" \
    && if [ -n "${TOKEN}" ]; then META="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" "${API}")"; else META="$(curl -fsSL "${API}")"; fi \
    && SHA="$(printf '%s' "${META}" | python3 -c "import sys, json; print(next(a['digest'].split(':')[1] for a in json.load(sys.stdin)['assets'] if a['name'] == '${FILE}'))")" \
    && (cd /tmp && echo "${SHA}  ${FILE}" | sha256sum -c) \
    && install -m 0755 "/tmp/${FILE}" /usr/local/bin/pre-commit \
    && rm "/tmp/${FILE}" \
    && pre-commit --version

# node — verified against the release's SHASUMS256.txt, which covers every
# architecture in one file. Node names its x86-64 build "x64", not "amd64".
RUN case "${TARGETARCH}" in \
        amd64) ARCH="x64" ;; \
        arm64) ARCH="arm64" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${NODE_URL}" | sed "s/linux-arm64/linux-${ARCH}/")" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL%/*}/SHASUMS256.txt" -o /tmp/SHASUMS256.txt \
    && (cd /tmp && sha256sum --ignore-missing -c SHASUMS256.txt) \
    && tar -xJ -C /usr/local --strip-components=1 -f "/tmp/${FILE}" \
    && rm "/tmp/${FILE}" /tmp/SHASUMS256.txt \
    && node --version

# pwsh (PowerShell) — verified against the release's hashes.sha256, which
# covers every architecture in one file. Unlike the other checksum files here,
# Microsoft publishes it as UTF-16 (with CRLF line endings), so it needs
# converting to UTF-8 before sha256sum can parse it. Like node, PowerShell
# names its x86-64 build "x64", not "amd64". The tarball has no top-level
# directory (its contents, including the pwsh binary, sit at tarball root), so
# it's extracted to Microsoft's documented install path and symlinked onto
# PATH from there, rather than merged into /usr/local like node's tarball.
RUN case "${TARGETARCH}" in \
        amd64) ARCH="x64" ;; \
        arm64) ARCH="arm64" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${PWSH_URL}" | sed "s/linux-arm64/linux-${ARCH}/")" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL%/*}/hashes.sha256" -o /tmp/pwsh.hashes.sha256.utf16 \
    && iconv -f UTF-16 -t UTF-8 /tmp/pwsh.hashes.sha256.utf16 > /tmp/pwsh.hashes.sha256 \
    && (cd /tmp && sha256sum --ignore-missing -c pwsh.hashes.sha256) \
    && mkdir -p /opt/microsoft/powershell/7 \
    && tar -xz -C /opt/microsoft/powershell/7 -f "/tmp/${FILE}" \
    && rm "/tmp/${FILE}" /tmp/pwsh.hashes.sha256 /tmp/pwsh.hashes.sha256.utf16 \
    && chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh \
    && pwsh --version

# gh (GitHub CLI) — verified against the release's checksums.txt, which covers
# every architecture in one file.
RUN case "${TARGETARCH}" in \
        amd64|arm64) ARCH="${TARGETARCH}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${GH_URL}" | sed "s/linux_arm64/linux_${ARCH}/")" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL%/*}/${FILE%%_linux_*}_checksums.txt" -o /tmp/gh.checksums.txt \
    && (cd /tmp && sha256sum --ignore-missing -c gh.checksums.txt) \
    && tar -xz -C /usr/local/bin --strip-components=2 -f "/tmp/${FILE}" "${FILE%.tar.gz}/bin/gh" \
    && rm "/tmp/${FILE}" /tmp/gh.checksums.txt \
    && gh --version \
    && gh completion -s bash > /etc/bash_completion.d/gh

# docker CLI — "Docker outside of Docker": the client only, no daemon. Docker
# commands run inside the container talk to the *host's* Docker daemon over a
# socket the consuming repo bind-mounts in (see README), so containers started
# from here are siblings on the host rather than nested children. That needs no
# privileged mode and no dockerd in this image.
#
# Docker names its x86-64 static build "x86_64" and its 64-bit Arm one
# "aarch64". The tarball unpacks a docker/ directory holding the whole engine
# (dockerd, containerd, runc, ...); only the client binary is extracted, since
# nothing here runs a daemon.
RUN case "${TARGETARCH}" in \
        amd64) SPEC="${DOCKER_CLI_URL_AMD64}" ;; \
        arm64) SPEC="${DOCKER_CLI_URL_ARM64}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="${SPEC%@sha256:*}" \
    && SHA="${SPEC##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/docker.tgz \
    && (cd /tmp && echo "${SHA}  docker.tgz" | sha256sum -c) \
    && tar -xz -C /usr/local/bin --strip-components=1 -f /tmp/docker.tgz docker/docker \
    && rm /tmp/docker.tgz \
    && docker --version \
    && docker completion bash > /etc/bash_completion.d/docker

# docker buildx and compose — CLI plugins, each shipped as a bare binary (no
# archive) and verified against its release's checksums.txt, which covers every
# architecture in one file. They go in one of the CLI's default system-wide
# plugin directories, so `docker buildx` / `docker compose` resolve for every
# user without per-user config. buildx names its assets "amd64"/"arm64";
# compose uses "x86_64"/"aarch64".
RUN case "${TARGETARCH}" in \
        amd64) BUILDX_ARCH="amd64"; COMPOSE_ARCH="x86_64" ;; \
        arm64) BUILDX_ARCH="arm64"; COMPOSE_ARCH="aarch64" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && PLUGINS=/usr/local/lib/docker/cli-plugins \
    && mkdir -p "${PLUGINS}" \
    && BUILDX="$(printf '%s' "${BUILDX_URL}" | sed "s/linux-arm64/linux-${BUILDX_ARCH}/")" \
    && COMPOSE="$(printf '%s' "${COMPOSE_URL}" | sed "s/linux-aarch64/linux-${COMPOSE_ARCH}/")" \
    && curl -fsSL "${BUILDX}" -o "/tmp/${BUILDX##*/}" \
    && curl -fsSL "${BUILDX%/*}/checksums.txt" -o /tmp/buildx.checksums.txt \
    && (cd /tmp && sha256sum --ignore-missing -c buildx.checksums.txt) \
    && install -m 0755 "/tmp/${BUILDX##*/}" "${PLUGINS}/docker-buildx" \
    && curl -fsSL "${COMPOSE}" -o "/tmp/${COMPOSE##*/}" \
    && curl -fsSL "${COMPOSE%/*}/checksums.txt" -o /tmp/compose.checksums.txt \
    && (cd /tmp && sha256sum --ignore-missing -c compose.checksums.txt) \
    && install -m 0755 "/tmp/${COMPOSE##*/}" "${PLUGINS}/docker-compose" \
    && rm "/tmp/${BUILDX##*/}" "/tmp/${COMPOSE##*/}" \
        /tmp/buildx.checksums.txt /tmp/compose.checksums.txt \
    && docker buildx version \
    && docker compose version

# Non-root access to the mounted socket can't be settled at build time: the
# socket's owning GID belongs to the host, and Docker Desktop mounts it owned
# by root, which no group membership can reach. So the group is only created
# here, and docker-socket-setup reconciles it with the real socket at container
# start (aligning the GID, or proxying a root-owned socket). It needs root, and
# consuming repos opt in explicitly — see README:
#   "postStartCommand": "sudo /usr/local/bin/docker-socket-setup"
# Without that hook the CLI still works for root and via sudo.
COPY docker-socket-setup.sh /usr/local/bin/docker-socket-setup
RUN chmod 0755 /usr/local/bin/docker-socket-setup \
    && groupadd --system docker \
    && usermod -aG docker vscode \
    && printf '\n# Pick up DOCKER_HOST when docker-socket-setup proxies a root-owned socket\n[[ -f /etc/profile.d/10-docker-host.sh ]] && source /etc/profile.d/10-docker-host.sh\n' \
        >> /home/vscode/.bashrc

# ble.sh — Fish-style inline autosuggestions (greyed-out completions drawn from
# shell history) for interactive bash. Verified against its hand-pinned SHA256
# digest, installed to /usr/share/blesh, then sourced from the vscode user's
# bashrc so every interactive shell picks it up. The bash-completion package
# installed above supplies the per-command completions (dig, rsync, wget, ...)
# that ble.sh surfaces inline.
RUN URL="${BLESH_URL%@sha256:*}" \
    && SHA="${BLESH_URL##*@sha256:}" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && (cd /tmp && echo "${SHA}  ${FILE}" | sha256sum -c) \
    && mkdir -p /usr/share/blesh \
    && tar -xJ -C /usr/share/blesh --strip-components=1 -f "/tmp/${FILE}" \
    && rm -f "/tmp/${FILE}" \
    && test -f /usr/share/blesh/ble.sh \
    && install -d -o vscode -g vscode /home/vscode/.cache \
    && printf '\n# Enable ble.sh: inline autosuggestions from history/completion\n[[ $- == *i* && -f /usr/share/blesh/ble.sh ]] && source /usr/share/blesh/ble.sh\n' \
        >> /home/vscode/.bashrc

USER vscode
