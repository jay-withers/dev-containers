#!/usr/bin/env bash
# Runs the smoke tests for the container images this repo builds: for each
# image, the commands listed in images/<name>/smoke-tests are executed inside
# that image, proving its tooling is actually present and runnable rather than
# merely installed without error.
#
# The list lives next to the Dockerfile that installs the tools, not in CI, for
# two reasons: adding a tool means editing two files in one directory, and the
# same checks CI runs can be run locally against a `make build` image without
# reaching for a workflow file. ci-container-build calls this script, so the
# two can't drift.
#
# Each image is tested by the job that builds it, so images/<name>/smoke-tests
# lists only what that image adds - a leaf image does not re-test the base
# tooling it inherits. A failure therefore names the image that broke.
#
# Images are discovered from the images/ directory, and the command list is
# discovered from within it, so adding a new image needs no change here or in
# the workflow - just images/<name>/Dockerfile and images/<name>/smoke-tests. A
# missing smoke-tests file is an error, not a silent pass: an untested image
# would otherwise look exactly like a passing one.
#
# Commands run inside the container with `set -e`, so the first failure stops
# that image and the script exits non-zero. Output is left on the terminal
# rather than swallowed - the printed versions are half the value when a
# wrong-architecture binary is what went wrong. Every image is attempted even
# after one fails, so a run reports every broken image, not just the first.
#
# Requires: docker. The image must already be built and available locally (or
# be pullable by the ref given).
#
# Usage:
#   ./scripts/smoke-test.sh                     # every image in images/, using its local `make build` tag
#   ./scripts/smoke-test.sh base                # one image, using its local tag
#   ./scripts/smoke-test.sh base ghcr.io/o/r/base:v1.2.3   # one image, explicit ref
#
# Env overrides:
#   IMAGES  space-separated image names to test (default: every directory in
#           images/). Ignored when an image is named as an argument.
#   ARCH    if set, assert the image reports this architecture (amd64, arm64)
#           before running anything. A mismatch means an install step pulled
#           the wrong asset - which otherwise shows up as a confusing runtime
#           failure, or not at all.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/images"

image_name="${1:-}"
image_ref="${2:-}"

if [ -n "${image_ref}" ] && [ -z "${image_name}" ]; then
    echo "smoke-test: an image ref needs an image name: smoke-test.sh <name> [ref]" >&2
    exit 2
fi

if [ -n "${image_name}" ]; then
    images="${image_name}"
elif [ -n "${IMAGES:-}" ]; then
    images="${IMAGES}"
else
    images=""
    for dir in "${IMAGES_DIR}"/*/; do
        [ -f "${dir}Dockerfile" ] || continue
        images="${images} $(basename "${dir}")"
    done
fi

if [ -z "${images// /}" ]; then
    echo "smoke-test: no images found in ${IMAGES_DIR}" >&2
    exit 1
fi

# Wraps a manifest line in single quotes so it can be embedded in the script
# built below purely for display, whatever punctuation it contains.
single_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Turns a manifest into a shell script: each command is announced and then run,
# with `set -e` stopping at the first failure.
container_script() {
    local manifest="$1" line
    printf 'set -e\n'
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in '' | '#'*) continue ;; esac
        printf 'printf "  %%s\\n" %s\n' "$(single_quote "${line}")"
        printf '%s\n' "${line}"
    done <"${manifest}"
}

failed=""

for image in ${images}; do
    manifest="${IMAGES_DIR}/${image}/smoke-tests"
    ref="${image_ref:-${image}}"

    if [ ! -f "${manifest}" ]; then
        echo "smoke-test: no smoke tests defined for image '${image}'" >&2
        echo "  expected a command list at ${manifest#"${REPO_ROOT}"/}" >&2
        failed="${failed} ${image}"
        continue
    fi

    echo "==> ${image} (${ref})"

    if [ -n "${ARCH:-}" ]; then
        got="$(docker image inspect --format '{{.Architecture}}' "${ref}")"
        if [ "${got}" != "${ARCH}" ]; then
            echo "smoke-test: expected ${ARCH} image, got ${got}" >&2
            failed="${failed} ${image}"
            continue
        fi
        echo "  architecture ${got}"
    fi

    if docker run --rm "${ref}" bash -c "$(container_script "${manifest}")"; then
        echo "  ${image}: ok"
    else
        echo "smoke-test: ${image} failed" >&2
        failed="${failed} ${image}"
    fi
done

if [ -n "${failed// /}" ]; then
    echo "smoke-test: failed:${failed}" >&2
    exit 1
fi

echo "smoke-test: all images passed"
