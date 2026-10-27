# Python app builder — python-app plus uv, for an app's builder stage. The
# venv it builds under /app/.venv is copied into python-app by the app's runtime
# stage, which is only safe because this image is python-app: same interpreter,
# same site-packages path. cd-publish builds it FROM python-app at the same
# version, so the two can't drift; an app should pin both at the same version.
ARG BASE_IMAGE="ghcr.io/jay-withers/dev-containers/python-app:latest"
FROM ${BASE_IMAGE}

# Back to root: uv's cache mount lives under /root/.cache/uv, and /app is
# root-owned in python-app. Only this stage runs as root; nothing from it ships
# except the venv an app copies out with --chown, so DL3002's "last USER should
# not be root" is about images that run, which this one never does.
# hadolint ignore=DL3002
USER 0

# uv is copied in rather than supplying the base image, which is exactly what
# lets the builder share the runtime's interpreter. UV_PYTHON_DOWNLOADS=never
# then stops uv fetching a different one of its own. Kept at the same version
# as base's UV_URL, so building locally and in an image resolve alike.
COPY --from=ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff /uv /uvx /bin/

# --no-editable belongs on each app's `uv sync`, not here: without it uv
# installs the project as a link back to /app/src, which the runtime stage
# never copies.
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never
