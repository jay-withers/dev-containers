# Kubernetes dev container — cluster tooling on top of the shared base.
ARG BASE_IMAGE="ghcr.io/jay-withers/dev-container/base:latest"
FROM ${BASE_IMAGE}

ARG HELM_URL="https://get.helm.sh/helm-v4.2.2-linux-arm64.tar.gz@sha256:596b9a73d366c1e72ce67d595c22805480e30914593aafbc9f547694e72814db"
ARG K9S_URL="https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_Linux_arm64.tar.gz@sha256:3ee05c82e5f9198928a4e86133608ba6a2c10a2244d6a7789e820f78319d640c"
ARG KUBECTL_URL="https://dl.k8s.io/release/v1.36.2/bin/linux/arm64/kubectl@sha256:c957eb8c4bea27a3bb35b269edd9082e27f027f7b76b20b5bf4afebc726c6d3e"
ARG KUBECTX_URL="https://github.com/ahmetb/kubectx/releases/download/v0.11.0/kubectx_v0.11.0_linux_arm64.tar.gz@sha256:1dac2072216689e773325cb7587b858ea7415706ebcf04e23bf80e7e70555340"

USER root

# kubectl with pinned SHA256 digest
RUN URL="${KUBECTL_URL%@sha256:*}" \
    && SHA="${KUBECTL_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /usr/local/bin/kubectl \
    && (cd /usr/local/bin && echo "${SHA}  kubectl" | sha256sum -c) \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client \
    && kubectl completion bash > /etc/bash_completion.d/kubectl

# kubectx with pinned SHA256 digest
RUN URL="${KUBECTX_URL%@sha256:*}" \
    && SHA="${KUBECTX_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/kubectx.tar.gz \
    && (cd /tmp && echo "${SHA}  kubectx.tar.gz" | sha256sum -c) \
    && tar -xz -C /usr/local/bin -f /tmp/kubectx.tar.gz kubectx \
    && rm /tmp/kubectx.tar.gz \
    && kubectx --version

# helm with pinned SHA256 digest
RUN URL="${HELM_URL%@sha256:*}" \
    && SHA="${HELM_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/helm.tar.gz \
    && (cd /tmp && echo "${SHA}  helm.tar.gz" | sha256sum -c) \
    && tar -xz -C /usr/local/bin --strip-components=1 -f /tmp/helm.tar.gz linux-arm64/helm \
    && rm /tmp/helm.tar.gz \
    && helm version \
    && helm completion bash > /etc/bash_completion.d/helm

# k9s with pinned SHA256 digest
RUN URL="${K9S_URL%@sha256:*}" \
    && SHA="${K9S_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/k9s.tar.gz \
    && (cd /tmp && echo "${SHA}  k9s.tar.gz" | sha256sum -c) \
    && tar -xz -C /usr/local/bin -f /tmp/k9s.tar.gz k9s \
    && rm /tmp/k9s.tar.gz \
    && k9s version

USER vscode
