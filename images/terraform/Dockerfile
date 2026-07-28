# Terraform dev container — Azure Terraform tooling on top of the shared base.
ARG BASE_IMAGE="ghcr.io/jay-withers/dev-containers/base:latest"
FROM ${BASE_IMAGE}

# Set automatically by BuildKit to the architecture being built for (amd64 or
# arm64). The downloads below are architecture-specific: each URL is written
# with the arm64 asset name, and the install step rewrites that token to
# whatever the upstream project calls the architecture being built. Keeping the
# version in a literal URL is what lets Renovate's custom managers find it.
ARG TARGETARCH

# Renovate bumps the version tag in these URLs; each download is verified at
# build time against the checksum the upstream project publishes for that version.
ARG CHECKOV_URL="https://github.com/bridgecrewio/checkov/releases/download/3.3.8/checkov_linux_arm64.zip"
ARG TERRAFORM_DOCS_URL="https://github.com/terraform-docs/terraform-docs/releases/download/v0.24.0/terraform-docs-v0.24.0-linux-arm64.tar.gz"
ARG TFLINT_URL="https://github.com/terraform-linters/tflint/releases/download/v0.64.0/tflint_linux_arm64.zip"

USER root

# checkov — no upstream checksum file, so verify against the sha256 digest the
# GitHub API reports for the release asset. The API call is authenticated when a
# gh_token secret is mounted (CI) to avoid unauthenticated rate limits, and falls
# back to an anonymous request otherwise (local builds).
# checkov names its x86-64 asset "X86_64" (capitalised), not "amd64".
RUN --mount=type=secret,id=gh_token \
    case "${TARGETARCH}" in \
        amd64) ARCH="X86_64" ;; \
        arm64) ARCH="arm64" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac; \
    URL="$(printf '%s' "${CHECKOV_URL}" | sed "s/linux_arm64/linux_${ARCH}/")"; \
    FILE="${URL##*/}"; \
    TAG="${URL#*/download/}"; TAG="${TAG%%/*}"; \
    API="https://api.github.com/repos/bridgecrewio/checkov/releases/tags/${TAG}"; \
    TOKEN="$(cat /run/secrets/gh_token 2>/dev/null || true)"; \
    curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && if [ -n "${TOKEN}" ]; then META="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" "${API}")"; else META="$(curl -fsSL "${API}")"; fi \
    && SHA="$(printf '%s' "${META}" | python3 -c "import sys, json; print(next(a['digest'].split(':')[1] for a in json.load(sys.stdin)['assets'] if a['name'] == '${FILE}'))")" \
    && (cd /tmp && echo "${SHA}  ${FILE}" | sha256sum -c) \
    && unzip "/tmp/${FILE}" -d /usr/local/bin \
    && mv /usr/local/bin/dist/checkov /usr/local/bin/checkov \
    && rm -rf /usr/local/bin/dist \
    && chmod +x /usr/local/bin/checkov \
    && rm "/tmp/${FILE}" \
    && checkov --version

# tflint — verified against the release's checksums.txt, which covers every
# architecture in one file.
RUN case "${TARGETARCH}" in \
        amd64|arm64) ARCH="${TARGETARCH}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${TFLINT_URL}" | sed "s/linux_arm64/linux_${ARCH}/")" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL%/*}/checksums.txt" -o /tmp/tflint.checksums.txt \
    && (cd /tmp && sha256sum --ignore-missing -c tflint.checksums.txt) \
    && unzip "/tmp/${FILE}" tflint -d /usr/local/bin \
    && rm "/tmp/${FILE}" /tmp/tflint.checksums.txt \
    && tflint --version

# terraform-docs — verified against the release's .sha256sum, which covers every
# architecture in one file.
RUN case "${TARGETARCH}" in \
        amd64|arm64) ARCH="${TARGETARCH}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${TERRAFORM_DOCS_URL}" | sed "s/linux-arm64/linux-${ARCH}/")" \
    && FILE="${URL##*/}" \
    && TAG="${URL#*/download/}" && TAG="${TAG%%/*}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL%/*}/terraform-docs-${TAG}.sha256sum" -o /tmp/terraform-docs.sha256sum \
    && (cd /tmp && sha256sum --ignore-missing -c terraform-docs.sha256sum) \
    && tar -xz -C /usr/local/bin -f "/tmp/${FILE}" terraform-docs \
    && chmod +x /usr/local/bin/terraform-docs \
    && rm "/tmp/${FILE}" /tmp/terraform-docs.sha256sum \
    && terraform-docs --version \
    && terraform-docs completion bash > /etc/bash_completion.d/terraform-docs

# tfenv — terraform version controlled by .terraform-version in the workspace
RUN git clone --depth=1 https://github.com/tfutils/tfenv.git /home/vscode/.tfenv \
    && chown -R vscode:vscode /home/vscode/.tfenv

ENV PATH="/home/vscode/.tfenv/bin:${PATH}"

USER vscode
