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
# Renovate bumps the version tag in these URLs; each download is verified at
# build time against the checksum the upstream project publishes for that version.
ARG GH_URL="https://github.com/cli/cli/releases/download/v2.98.0/gh_2.98.0_linux_arm64.tar.gz"
ARG NODE_URL="https://nodejs.org/dist/v24.19.0/node-v24.19.0-linux-arm64.tar.xz"
# pre-commit ships a single architecture-independent .pyz zipapp.
ARG PRE_COMMIT_URL="https://github.com/pre-commit/pre-commit/releases/download/v3.8.0/pre-commit-3.8.0.pyz"

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
        bind9-dnsutils iputils-ping traceroute netcat-openbsd \
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

# pre-commit — verified against the release's .pyz.sha256sum
RUN FILE="${PRE_COMMIT_URL##*/}" \
    && curl -fsSL "${PRE_COMMIT_URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${PRE_COMMIT_URL}.sha256sum" -o /tmp/pre-commit.sha256sum \
    && (cd /tmp && sha256sum --ignore-missing -c pre-commit.sha256sum) \
    && install -m 0755 "/tmp/${FILE}" /usr/local/bin/pre-commit \
    && rm "/tmp/${FILE}" /tmp/pre-commit.sha256sum \
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
