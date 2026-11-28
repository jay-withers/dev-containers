# Node app builder: node-app plus npm, for an app's build stage, the
# counterpart of python-app-builder. An app runs `npm ci` here and copies its
# node_modules into node-app. cd-publish builds it FROM node-app at the same
# version, so native modules (if an app ever has one) are built for exactly
# the Node and OS it runs on; an app should pin both at the same version.
#
# The default BASE_IMAGE carries no digest until node-app's first release; CI
# and cd-publish always pass the parent explicitly, and Renovate pins this
# once a release exists.
ARG BASE_IMAGE="ghcr.io/jay-withers/dev-containers/node-app:latest@sha256:038abb35466588df62e18ad6e67389a9508c3c1eb6c8967931a0db5193ca827a"

# npm is copied out of the official image at node-app's tag rather than
# installed, as dotnet-app-builder copies the SDK in: it is the npm that Node
# release bundles, which is the one mise's Node brings to CI. Keep the two
# tags equal: jay-withers/renovate's npm preset moves both minors and patches
# in one `mise tools` PR, and docker.json's `docker digests` group moves both
# digests together.
FROM node:26.13.1-bookworm-slim@sha256:0042e17d232a87a2cd485be1da7900fca4d10a4ad11b29e9285da1d2e54798c9 AS node

FROM ${BASE_IMAGE}

# Back to root: npm's cache and an app's install run as root here, and /app
# is root-owned in node-app. Nothing from this stage ships except what an app
# copies out, so DL3002 does not apply.
# hadolint ignore=DL3002
USER 0

COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# A build installs dev dependencies too (an app's typecheck and tests run
# here), so the runtime's production default is lifted for this stage.
ENV NODE_ENV=development \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false
