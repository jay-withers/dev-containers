# Python app runtime — the image every Python app on the shared Container Apps
# environment runs FROM. Not a dev container: no tooling, no vscode user, and
# nothing here is meant to be worked inside. It holds what those apps used to
# repeat in their own Dockerfiles, and had drifted on: the Python digest, the
# OS security patches, pip's removal and the non-root user.
#
# Its partner, python-app-builder, is built FROM this image in the same publish,
# so an app that builds its venv in one and runs it in the other gets the same
# interpreter in both by construction. A venv is bound to the exact minor
# version that created it; gym-log's Dockerfile tells the market-agent outage
# that taught this.
FROM python:3.14-slim-bookworm@sha256:9974e24551f9e7ca172cf284d85b8ab3e031d22d945f7026ede7a8279118c9f1

# Links the package to this repository, which is what gives a workflow's
# GITHUB_TOKEN write access to it. Inherited by every app image built FROM
# this one, so each app must keep setting its own (they all do) or its image
# would be linked here instead.
LABEL org.opencontainers.image.source="https://github.com/jay-withers/dev-containers"

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# cd-publish sets this to the version being published. An ARG's value is part
# of the cache key of every RUN after it, so a new value forces the apt layer
# below to re-run. Without it, cd-weekly's rebuild would restore that layer
# from the GHA cache — the FROM digest and the instruction both unchanged — and
# republish last week's packages under a new version. Local and PR builds leave
# it empty and cache as normal.
ARG REBUILD=""

# Debian's published security fixes, applied on every publish rather than
# waiting for the python image to be rebuilt upstream (libssl3, CVE-2026-84782,
# was what made repo-agent and market-agent patch this by hand).
#
# The same layer removes the base image's pip, which vendors certifi, urllib3,
# msgpack and setuptools' pkg_resources at whatever versions shipped with it;
# Trivy reports them. Nothing at runtime uses pip: apps run from a venv that uv
# built without one.
#
# The user is numeric and USER names the number, not the name: a runtime
# enforcing runAsNonRoot has to resolve the user before the container starts,
# and it cannot read this image's /etc/passwd to do it. No login shell —
# nothing in here needs to log in.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall --yes --root-user-action=ignore pip \
    && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin app

# Created before USER, so /app is root-owned: an app copies its venv in with
# --chown=10001:10001 and nothing else under /app is writable at runtime.
WORKDIR /app

USER 10001
