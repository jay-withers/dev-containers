# Kubernetes dev container — cluster tooling on top of the shared base.
ARG BASE_IMAGE="ghcr.io/jay-withers/dev-container/base:latest"
FROM ${BASE_IMAGE}

# Renovate bumps the version tag in these URLs; each download is verified at
# build time against the checksum the upstream project publishes for that version.
ARG HELM_URL="https://get.helm.sh/helm-v4.2.3-linux-arm64.tar.gz"
ARG K9S_URL="https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_arm64.tar.gz"
ARG KUBECTL_URL="https://dl.k8s.io/release/v1.36.3/bin/linux/arm64/kubectl"
# kubectx is not tracked by Renovate, so it stays pinned to a specific
# @sha256: digest that is bumped by hand.
ARG KUBECTX_URL="https://github.com/ahmetb/kubectx/releases/download/v0.11.0/kubectx_v0.11.0_linux_arm64.tar.gz@sha256:1dac2072216689e773325cb7587b858ea7415706ebcf04e23bf80e7e70555340"

USER root

# kubectl — verified against the release's kubectl.sha256 (bare digest)
RUN curl -fsSL "${KUBECTL_URL}" -o /tmp/kubectl \
    && curl -fsSL "${KUBECTL_URL}.sha256" -o /tmp/kubectl.sha256 \
    && (cd /tmp && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c) \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm /tmp/kubectl /tmp/kubectl.sha256 \
    && kubectl version --client \
    && kubectl completion bash > /etc/bash_completion.d/kubectl

# kubectx — verified against its hand-pinned SHA256 digest
RUN URL="${KUBECTX_URL%@sha256:*}" \
    && SHA="${KUBECTX_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/kubectx.tar.gz \
    && (cd /tmp && echo "${SHA}  kubectx.tar.gz" | sha256sum -c) \
    && tar -xz -C /usr/local/bin -f /tmp/kubectx.tar.gz kubectx \
    && rm /tmp/kubectx.tar.gz \
    && kubectx --version

# helm — verified against the release's .tar.gz.sha256sum
RUN FILE="${HELM_URL##*/}" \
    && curl -fsSL "${HELM_URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${HELM_URL}.sha256sum" -o /tmp/helm.sha256sum \
    && (cd /tmp && sha256sum --ignore-missing -c helm.sha256sum) \
    && tar -xz -C /usr/local/bin --strip-components=1 -f "/tmp/${FILE}" linux-arm64/helm \
    && rm "/tmp/${FILE}" /tmp/helm.sha256sum \
    && helm version \
    && helm completion bash > /etc/bash_completion.d/helm

# k9s — verified against the release's checksums.sha256
RUN FILE="${K9S_URL##*/}" \
    && curl -fsSL "${K9S_URL}" -o "/tmp/${FILE}" \
    && curl -fsSL "${K9S_URL%/*}/checksums.sha256" -o /tmp/k9s.checksums.sha256 \
    && (cd /tmp && sha256sum --ignore-missing -c k9s.checksums.sha256) \
    && tar -xz -C /usr/local/bin -f "/tmp/${FILE}" k9s \
    && rm "/tmp/${FILE}" /tmp/k9s.checksums.sha256 \
    && k9s version

USER vscode
