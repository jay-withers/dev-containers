# Node app runtime: the image every TypeScript/Node app on the shared Container
# Apps environment runs FROM, the counterpart of python-app and dotnet-app.
# Not a dev container: no npm and no tooling, only Node, the OS security
# patches and the non-root user. An app whose base must be another image
# (security-testing's is ZAP's) copies /usr/local/bin/node out of this one
# instead, so it still gets this Node.
#
# Its partner, node-app-builder, is built FROM this image in the same publish
# and adds npm, so an app installs its node_modules against exactly the Node
# and OS it will run on.
#
# Debian bookworm, slim: apt, so the REBUILD layer below applies Debian's
# security fixes between the Node project's releases, and the same glibc as
# python-app and the ZAP image, so the node binary copies across as it is. The
# exact Node version is in the tag, and should be the one the apps' mise.toml
# pins: CI tests on mise's Node, and this one ships. Renovate moves its minors
# and patches, and never raises its major (jay-withers/renovate's npm preset).
FROM node:26.13.1-bookworm-slim@sha256:0042e17d232a87a2cd485be1da7900fca4d10a4ad11b29e9285da1d2e54798c9

# Links the package to this repository, which is what gives a workflow's
# GITHUB_TOKEN write access to it. Inherited by every app image built FROM
# this one, so each app must set its own.
LABEL org.opencontainers.image.source="https://github.com/jay-withers/dev-containers"

ENV NODE_ENV=production

# cd-publish sets this to the version being published, which forces the apt
# layer below past the GHA cache on every publish, as in python-app.
ARG REBUILD=""

# Debian's published security fixes, applied on every publish. The same layer
# removes what the base image bundles beside node: npm, npx, corepack and
# yarn. They vendor their own dependency trees, which Trivy reports, and
# nothing at runtime installs a package (python-app drops pip for the same
# reason). node-app-builder puts npm back for the build stage.
#
# The base's `node` user (uid 1000) is replaced by uid 10001, the uid every app
# image here runs as, under the name `app`. Numeric USER, as in python-app: a
# runtime enforcing runAsNonRoot resolves it without reading /etc/passwd. Its
# group is the system one useradd picks, as in python-app and dotnet-app: apps
# copy files in with --chown=10001:10001, and nothing relies on group access.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /usr/local/lib/node_modules /opt/yarn-* \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
        /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && userdel --remove node \
    && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin app

# Created before USER, so /app is root-owned: an app copies its sources and
# node_modules in, and nothing under /app is writable at runtime.
WORKDIR /app

USER 10001
