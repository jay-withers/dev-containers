# .NET app builder: dotnet-app plus the SDK, for an app's build stage, the
# counterpart of python-app-builder. An app restores and publishes here and
# copies the output into dotnet-app. cd-publish builds it FROM dotnet-app at
# the same version, so the builder has exactly the runtime and OS the app
# runs on; an app should pin both at the same version.
#
# The default BASE_IMAGE carries no digest until dotnet-app's first release;
# CI and cd-publish always pass the parent explicitly, and Renovate pins this
# once a release exists.
ARG BASE_IMAGE="ghcr.io/jay-withers/dev-containers/dotnet-app:latest@sha256:553c52ab245181b443de271c0f8157585c1a6009a3ddab8d19bc509162e0a0b0"

# The SDK is copied out of Microsoft's SDK image rather than built FROM it, as
# python-app-builder copies uv in, so this stays dotnet-app underneath. The
# SDK's own copy of the runtime lands on dotnet-app's, which is the same
# release while the two tags move together (renovate's docker preset groups
# them); smoke-tests fails on a second runtime, which is how a drift shows.
# The SDK version is in the tag, and should be the one the apps' mise.toml
# pins: CI tests on mise's SDK, and this one builds what ships.
FROM mcr.microsoft.com/dotnet/sdk:11.0.100-resolute@sha256:2794448a07118a6eaf00f29ab5d2bf44928517ce5ff86505a63a69230374f599 AS sdk

FROM ${BASE_IMAGE}

# Back to root: the SDK's NuGet cache and an app's restore run as root here,
# and /app is root-owned in dotnet-app. Nothing from this stage ships except
# the published output an app copies out with --chown, so DL3002 does not
# apply.
# hadolint ignore=DL3002
USER 0

COPY --from=sdk /usr/share/dotnet /usr/share/dotnet

# The SDK image's own settings for a build: no first-run work or telemetry,
# and NuGet skips the XML docs it would otherwise unpack with every package.
ENV DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_GENERATE_ASPNET_CERTIFICATE=false \
    NUGET_XMLDOC_MODE=skip
