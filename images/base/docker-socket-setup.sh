#!/usr/bin/env bash
# Gives the container's non-root user access to the host Docker socket that the
# consuming repo bind-mounts in ("Docker outside of Docker" - the CLI in this
# image talks to the host's daemon, so containers started here are siblings on
# the host rather than nested children).
#
# This has to run at container start rather than at image build time, because
# the thing it reacts to - who owns the socket - is a property of the host, not
# of the image. Two cases, and which one applies is not knowable until the
# socket is actually mounted:
#
#   - Socket owned by a non-root group (the usual native-Linux case). The
#     group's GID is whatever that host's docker group happens to be, so the
#     container is made to agree with it: the local `docker` group is moved to
#     that GID (or, if some other group already holds it, that group is used
#     instead) and the target user is added.
#
#   - Socket owned by root (what Docker Desktop mounts, on macOS and Windows).
#     No group membership can reach a root-owned socket, and loosening its mode
#     would change permissions on the host's own socket file, so instead socat
#     proxies it to a second socket owned by the target user. DOCKER_HOST is
#     pointed at the proxy via a profile snippet the image's .bashrc sources.
#
# Must run as root (the group and proxy changes both need it), so invoke it with
# sudo - the vscode user has passwordless sudo:
#
#   "postStartCommand": "sudo /usr/local/bin/docker-socket-setup"
#
# Safe to run repeatedly: postStartCommand fires on every container start, and
# each step here is idempotent.
#
# Usage: docker-socket-setup [user]   (user defaults to vscode)

set -euo pipefail

SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"
PROXY_SOCKET="${DOCKER_PROXY_SOCKET:-/var/run/docker-host.sock}"
PROFILE_SNIPPET=/etc/profile.d/10-docker-host.sh
PROXY_LOG=/var/log/docker-socket-proxy.log
TARGET_USER="${1:-vscode}"

if [ "$(id -u)" -ne 0 ]; then
    echo "docker-socket-setup: must run as root (try: sudo $0 $*)" >&2
    exit 1
fi

if ! id "${TARGET_USER}" >/dev/null 2>&1; then
    echo "docker-socket-setup: no such user '${TARGET_USER}'" >&2
    exit 1
fi

# Nothing to do - and nothing that would work - without the mount. Failing here
# rather than silently doing nothing is the point: it names the missing piece.
if [ ! -S "${SOCKET}" ]; then
    echo "docker-socket-setup: ${SOCKET} is not a socket - the host Docker socket" \
        "does not appear to be mounted into this container." >&2
    echo "Add it to the consuming repo's devcontainer.json, e.g.:" >&2
    echo '  "mounts": ["source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"]' >&2
    exit 1
fi

socket_gid="$(stat -c '%g' "${SOCKET}")"

if [ "${socket_gid}" -ne 0 ]; then
    # A group already holding this GID is used as-is; renumbering it would
    # break whatever else in the image belongs to it. getent exits non-zero
    # when nothing holds the GID, which is the normal case here, so it must not
    # trip pipefail.
    existing_group="$(getent group "${socket_gid}" 2>/dev/null | cut -d: -f1 || true)"

    if [ -n "${existing_group}" ]; then
        group_name="${existing_group}"
    else
        group_name=docker
        groupmod -g "${socket_gid}" docker
    fi

    usermod -aG "${group_name}" "${TARGET_USER}"

    # Only the group path needs no proxy, so drop any snippet a previous run
    # left behind - the socket may well have changed owner since.
    rm -f "${PROFILE_SNIPPET}"

    echo "docker-socket-setup: ${TARGET_USER} added to group '${group_name}'" \
        "(gid ${socket_gid}) for ${SOCKET}"
    exit 0
fi

# Root-owned socket: proxy it to one the user can open.
if [ -S "${PROXY_SOCKET}" ] && pgrep -f "UNIX-LISTEN:${PROXY_SOCKET}" >/dev/null 2>&1; then
    echo "docker-socket-setup: proxy already running on ${PROXY_SOCKET}"
else
    rm -f "${PROXY_SOCKET}"
    nohup socat \
        "UNIX-LISTEN:${PROXY_SOCKET},fork,mode=660,user=${TARGET_USER},group=${TARGET_USER}" \
        "UNIX-CONNECT:${SOCKET}" \
        >"${PROXY_LOG}" 2>&1 &

    # socat creates the listening socket a moment after forking; without the
    # wait, a postStartCommand can finish before DOCKER_HOST is usable.
    for _ in $(seq 1 50); do
        [ -S "${PROXY_SOCKET}" ] && break
        sleep 0.1
    done

    if [ ! -S "${PROXY_SOCKET}" ]; then
        echo "docker-socket-setup: socat did not create ${PROXY_SOCKET};" \
            "see ${PROXY_LOG}" >&2
        exit 1
    fi

    echo "docker-socket-setup: proxying root-owned ${SOCKET} to ${PROXY_SOCKET}" \
        "for ${TARGET_USER}"
fi

# Sourced by the image's .bashrc, so interactive shells pick up the proxy.
cat >"${PROFILE_SNIPPET}" <<EOF
# Written by docker-socket-setup: the host socket is root-owned, so the Docker
# CLI is pointed at the user-owned proxy socket instead.
export DOCKER_HOST="unix://${PROXY_SOCKET}"
EOF
chmod 0644 "${PROFILE_SNIPPET}"

echo "docker-socket-setup: DOCKER_HOST set via ${PROFILE_SNIPPET}" \
    "(new shells; run 'source ${PROFILE_SNIPPET}' in existing ones)"
