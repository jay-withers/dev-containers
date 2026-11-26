# .NET app runtime: the image every .NET app on the shared Container Apps
# environment runs FROM, the counterpart of python-app. Not a dev container:
# no SDK and no tooling, only the ASP.NET Core runtime (which carries the .NET
# runtime too, so a console app or a job runs on it as well), the OS security
# patches and the non-root user.
#
# Its partner, dotnet-app-builder, is built FROM this image in the same
# publish and adds the SDK, so an app builds against exactly the runtime and
# OS it will run on.
#
# Ubuntu (resolute), not chiseled or distroless: those have no apt, so the
# REBUILD layer below could not apply Ubuntu's security fixes between
# Microsoft's releases, and every app's Trivy gate would wait on Microsoft.
# The exact runtime version is in the tag, so Renovate's PR says which runtime
# it moves to; it moves with dotnet-app-builder's SDK image in one PR.
FROM mcr.microsoft.com/dotnet/aspnet:11.0.0-resolute@sha256:ca396ece3f2a2e62c7a03f1d7d710b8bc7e8c9dea5597d091178d9f5bfca13f0

# Links the package to this repository, which is what gives a workflow's
# GITHUB_TOKEN write access to it. Inherited by every app image built FROM
# this one, so each app must set its own.
LABEL org.opencontainers.image.source="https://github.com/jay-withers/dev-containers"

# APP_UID is the base image's own name for its non-root user, read by tools
# such as the SDK's container publishing. It names the user created below.
# DOTNET_CLI_TELEMETRY_OPTOUT covers anything an app runs through the dotnet
# host at runtime. ASPNETCORE_HTTP_PORTS stays the base's 8080; an app on
# another port sets its own.
ENV APP_UID=10001 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1

# cd-publish sets this to the version being published, which forces the apt
# layer below past the GHA cache on every publish, as in python-app.
ARG REBUILD=""

# Ubuntu's published security fixes, applied on every publish. The base's
# `app` user (uid 1654) is replaced by uid 10001, the uid every app image here
# runs as, under the same name. Numeric USER, as in python-app: a runtime
# enforcing runAsNonRoot resolves it without reading /etc/passwd. Its group
# is the system one useradd picks (999), deliberately the same as python-app's:
# apps copy files in with --chown=10001:10001, owner-writable only, and
# nothing in either image relies on group access.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && userdel --remove app \
    && useradd --system --uid 10001 --create-home --shell /usr/sbin/nologin app

# Created before USER, so /app is root-owned: an app copies its published
# output in with --chown=10001:10001 and nothing else under /app is writable.
WORKDIR /app

USER 10001
