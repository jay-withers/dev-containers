# Kubernetes dev container — cluster tooling on top of the shared base.
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
ARG HELM_URL="https://get.helm.sh/helm-v4.2.4-linux-arm64.tar.gz"
ARG K9S_URL="https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_arm64.tar.gz"
ARG KUBECTL_URL="https://dl.k8s.io/release/v1.37.0/bin/linux/arm64/kubectl"
# kubectx is not tracked by Renovate, so its version is bumped by hand. It does
# publish a checksums.txt covering every architecture, which is what the install
# step below verifies against.
ARG KUBECTX_URL="https://github.com/ahmetb/kubectx/releases/download/v0.11.0/kubectx_v0.11.0_linux_arm64.tar.gz"

USER root

# kubectl — verified against the release's kubectl.sha256 (bare digest)
RUN case "${TARGETARCH}" in \
        amd64|arm64) ARCH="${TARGETARCH}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${KUBECTL_URL}" | sed "s|/linux/arm64/|/linux/${ARCH}/|")" \
    && curl -fsSL "${URL}" -o /tmp/kubectl \
    && curl -fsSL "${URL}.sha256" -o /tmp/kubectl.sha256 \
    && (cd /tmp && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c) \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm /tmp/kubectl /tmp/kubectl.sha256 \
    && kubectl version --client \
    && kubectl completion bash > /etc/bash_completion.d/kubectl

# kubectx — verified against the release's checksums.txt, which covers every
# architecture in one file. kubectx names its x86-64 asset "x86_64", not "amd64".
RUN case "${TARGETARCH}" in \
        amd64) ARCH="x86_64" ;; \
        arm64) ARCH="arm64" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${KUBECTX_URL}" | sed "s/linux_arm64/linux_${ARCH}/")" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL%/*}/checksums.txt" -o /tmp/kubectx.checksums.txt \
    && (cd /tmp && sha256sum --ignore-missing -c kubectx.checksums.txt) \
    && tar -xz -C /usr/local/bin -f "/tmp/${FILE}" kubectx \
    && rm "/tmp/${FILE}" /tmp/kubectx.checksums.txt \
    && kubectx --version

# helm — verified against the release's .tar.gz.sha256sum. The archive nests the
# binary under a linux-<arch>/ directory, so that path is arch-specific too.
RUN case "${TARGETARCH}" in \
        amd64|arm64) ARCH="${TARGETARCH}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${HELM_URL}" | sed "s/linux-arm64/linux-${ARCH}/")" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL}.sha256sum" -o /tmp/helm.sha256sum \
    && (cd /tmp && sha256sum --ignore-missing -c helm.sha256sum) \
    && tar -xz -C /usr/local/bin --strip-components=1 -f "/tmp/${FILE}" "linux-${ARCH}/helm" \
    && rm "/tmp/${FILE}" /tmp/helm.sha256sum \
    && helm version \
    && helm completion bash > /etc/bash_completion.d/helm

# k9s — verified against the release's checksums.sha256, which covers every
# architecture in one file.
RUN case "${TARGETARCH}" in \
        amd64|arm64) ARCH="${TARGETARCH}" ;; \
        *) echo "unsupported TARGETARCH '${TARGETARCH}' (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
    && URL="$(printf '%s' "${K9S_URL}" | sed "s/Linux_arm64/Linux_${ARCH}/")" \
    && FILE="${URL##*/}" \
    && curl -fsSL "${URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${URL%/*}/checksums.sha256" -o /tmp/k9s.checksums.sha256 \
    && (cd /tmp && sha256sum --ignore-missing -c k9s.checksums.sha256) \
    && tar -xz -C /usr/local/bin -f "/tmp/${FILE}" k9s \
    && rm "/tmp/${FILE}" /tmp/k9s.checksums.sha256 \
    && k9s version

USER vscode
