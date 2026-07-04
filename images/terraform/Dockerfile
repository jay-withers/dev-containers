# Terraform dev container — Azure Terraform tooling on top of the shared base.
ARG BASE_IMAGE="ghcr.io/jay-withers/dev-container/base:latest"
FROM ${BASE_IMAGE}

ARG CHECKOV_URL="https://github.com/bridgecrewio/checkov/releases/download/3.3.6/checkov_linux_arm64.zip@sha256:fff55b064eadfc14ce35da9b9744dedf82fb50c25447076149480ad92c06a6a9"
ARG TERRAFORM_DOCS_URL="https://github.com/terraform-docs/terraform-docs/releases/download/v0.24.0/terraform-docs-v0.24.0-linux-arm64.tar.gz@sha256:d12bd7b73c1fc9c64efc79f8157dd713dabd559f1ecf3cfc0f42e32279a155fd"
ARG TFLINT_URL="https://github.com/terraform-linters/tflint/releases/download/v0.63.1/tflint_linux_arm64.zip@sha256:999c25cfdb5208fe1133dec6b219e666a39fc2a7a0786a781dc9924ea5945ebf"

USER root

# checkov binary with pinned SHA256 digest
RUN URL="${CHECKOV_URL%@sha256:*}" \
    && SHA="${CHECKOV_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/checkov.zip \
    && (cd /tmp && echo "${SHA}  checkov.zip" | sha256sum -c) \
    && unzip /tmp/checkov.zip -d /usr/local/bin \
    && mv /usr/local/bin/dist/checkov /usr/local/bin/checkov \
    && rm -rf /usr/local/bin/dist \
    && chmod +x /usr/local/bin/checkov \
    && rm /tmp/checkov.zip \
    && checkov --version

# tflint with pinned SHA256 digest
RUN URL="${TFLINT_URL%@sha256:*}" \
    && SHA="${TFLINT_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/tflint.zip \
    && (cd /tmp && echo "${SHA}  tflint.zip" | sha256sum -c) \
    && unzip /tmp/tflint.zip tflint -d /usr/local/bin \
    && rm /tmp/tflint.zip \
    && tflint --version

# terraform-docs with pinned SHA256 digest
RUN URL="${TERRAFORM_DOCS_URL%@sha256:*}" \
    && SHA="${TERRAFORM_DOCS_URL##*@sha256:}" \
    && curl -fsSL "${URL}" -o /tmp/terraform-docs.tar.gz \
    && (cd /tmp && echo "${SHA}  terraform-docs.tar.gz" | sha256sum -c) \
    && tar -xz -C /usr/local/bin -f /tmp/terraform-docs.tar.gz terraform-docs \
    && chmod +x /usr/local/bin/terraform-docs \
    && rm /tmp/terraform-docs.tar.gz \
    && terraform-docs --version \
    && terraform-docs completion bash > /etc/bash_completion.d/terraform-docs

# tfenv — terraform version controlled by .terraform-version in the workspace
RUN git clone --depth=1 https://github.com/tfutils/tfenv.git /home/vscode/.tfenv \
    && chown -R vscode:vscode /home/vscode/.tfenv

ENV PATH="/home/vscode/.tfenv/bin:${PATH}"

USER vscode
