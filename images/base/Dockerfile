FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Shared base image for all dev containers in this repo.
# Specialised images (terraform, k8s, ...) build FROM this.

ARG AZURE_CLI_URL="https://packages.microsoft.com/repos/azure-cli/pool/main/a/azure-cli/azure-cli_2.73.0-1~noble_arm64.deb@sha256:6af9009a39895ba396e92d5138824091e95f9bd797422db2fe9564a0cf4a35f4"
ARG NODE_URL="https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-arm64.tar.xz@sha256:524659219d6a207a7400f2bde15d19ba060ffbe0d32a8643319ad67e3bb64c78"
ARG PRE_COMMIT_URL="https://github.com/pre-commit/pre-commit/releases/download/v3.8.0/pre-commit-3.8.0.pyz@sha256:a0349324f0f53b08d00eb473b5f6646c8a07f3253703c09b977b0b9b9476d486"

# Base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash-completion curl unzip xz-utils python3 \
    && rm -rf /var/lib/apt/lists/*

# azure-cli with pinned SHA256 digest
RUN URL="${AZURE_CLI_URL%@sha256:*}" \
    && SHA="${AZURE_CLI_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/azure-cli.deb \
    && (cd /tmp && echo "${SHA}  azure-cli.deb" | sha256sum -c) \
    && apt-get update && apt-get install -y --no-install-recommends /tmp/azure-cli.deb \
    && rm /tmp/azure-cli.deb \
    && rm -rf /var/lib/apt/lists/* \
    && az --version

# pre-commit with pinned SHA256 digest
RUN URL="${PRE_COMMIT_URL%@sha256:*}" \
    && SHA="${PRE_COMMIT_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /usr/local/bin/pre-commit \
    && (cd /usr/local/bin && echo "${SHA}  pre-commit" | sha256sum -c) \
    && chmod +x /usr/local/bin/pre-commit \
    && pre-commit --version

# node with pinned SHA256 digest
RUN URL="${NODE_URL%@sha256:*}" \
    && SHA="${NODE_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/node.tar.xz \
    && (cd /tmp && echo "${SHA}  node.tar.xz" | sha256sum -c) \
    && tar -xJ -C /usr/local --strip-components=1 -f /tmp/node.tar.xz \
    && rm /tmp/node.tar.xz \
    && node --version

USER vscode
