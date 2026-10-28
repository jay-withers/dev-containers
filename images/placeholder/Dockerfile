# Placeholder app — the image an app's Terraform creates its container app
# with, before the app's first release exists. Not a dev container. It answers
# 200 on every path, on $PORT, so the first apply succeeds and the revision is
# healthy whatever the app's probes point at; the app's own pipeline then
# deploys the real image over it (`ignore_changes` on the image keeps Terraform
# from putting it back).
#
# It replaces seeding the first revision with a guessed release tag: a tag that
# doesn't exist yet passes plan and apply and only fails at revision start-up,
# and cd-tag's first release is v0.0.1 or v0.1.0 depending on the repo's
# history (observability#4 fixed exactly that).
FROM golang:1.27-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS build

WORKDIR /src
COPY main.go .
# Static, so the runtime stage needs no libc of Go's choosing; trimpath and
# stripped symbols keep the build reproducible and small.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /placeholder main.go

# Alpine rather than scratch because smoke-test.sh runs each image's checks
# through a shell inside it.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

LABEL org.opencontainers.image.source="https://github.com/jay-withers/dev-containers"

# Same reason as python-app's: a new value per published version forces the
# upgrade layer below past the GHA cache.
ARG REBUILD=""

# Alpine's published security fixes, applied on every publish. The user is
# numeric, as in python-app, so a runtime enforcing runAsNonRoot can resolve
# it without reading /etc/passwd.
RUN apk upgrade --no-cache \
    && adduser -S -D -H -u 10001 app

COPY --from=build /placeholder /usr/local/bin/placeholder

USER 10001
EXPOSE 8080
# ENTRYPOINT, not CMD: an app's `args` (`serve`, `insight --email`) replace
# CMD but are only passed to an ENTRYPOINT, which ignores them.
ENTRYPOINT ["/usr/local/bin/placeholder"]
