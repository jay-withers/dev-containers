#!/usr/bin/env bash
# Scans the container images this repo publishes for known vulnerabilities with
# Trivy and prints a markdown report on stdout (progress goes to stderr, so the
# report can be redirected to a file on its own).
#
# Report-only by design. A vulnerability never fails this script - the exit code
# reflects whether the *scans ran*, not what they found - so a CVE disclosure
# can't block a publish or hold up a Renovate auto-merge. A scan that fails to
# run does exit non-zero, because that means the report is incomplete and the
# reader would otherwise read silence as "nothing found".
#
# What it scans: the published multi-arch image for each directory in images/,
# at TAG, for each platform in PLATFORMS. Trivy reads the per-platform manifest
# straight out of the registry, so both architectures are scanned from one
# runner with no emulation - nothing here executes the image.
#
# Kernel headers are reported separately, not in the headline. Ubuntu's
# linux-libc-dev package carries the CVE record of every kernel fix, which on
# the current base is ~370 HIGH/CRITICAL findings - and every one is a header
# file. A container ships no kernel, so none of them is reachable; left in the
# headline they bury the handful of findings that are real. They are counted and
# called out, never silently dropped. IGNORE_PKGS holds the list.
#
# Findings are deduplicated across platforms on (CVE, package), since the two
# architectures install the same apt packages and would otherwise double every
# count; the platforms a finding was seen on travel with it in the report.
#
# Requires: jq, plus either trivy on PATH or docker (the script falls back to
# running trivy from a container). The images are public, so no registry
# credentials are needed; for a private package, either log in with docker (the
# fallback mounts ~/.docker read-only) or use a trivy on PATH.
#
# Usage:
#   ./scripts/scan-images.sh                 # report to stdout
#   ./scripts/scan-images.sh > report.md     # report to a file, progress to the terminal
#
# Env overrides:
#   REPO         owner/name (default: current repo via gh)
#   TAG          image tag to scan (default: latest)
#   PLATFORMS    space- or comma-separated platforms (default: linux/amd64 linux/arm64)
#   IMAGES       space-separated image names (default: every directory in images/)
#   IGNORE_PKGS  packages held out of the headline counts and reported
#                separately (default: linux-libc-dev)
#   MAX_ROWS     most detail rows to table per image; the remainder is reported
#                as a count rather than dropped silently. The default is set
#                above the count these images actually carry, so a normal run
#                tables everything; it exists to stop a pathological result set
#                from producing an unreadable report (default: 200)
#   TRIVY_IMAGE  image used when trivy is not on PATH
#                (default: ghcr.io/aquasecurity/trivy:latest)

set -euo pipefail

TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64 linux/arm64}"
IGNORE_PKGS="${IGNORE_PKGS:-linux-libc-dev}"
MAX_ROWS="${MAX_ROWS:-200}"
TRIVY_IMAGE="${TRIVY_IMAGE:-ghcr.io/aquasecurity/trivy:latest}"
TRIVY_CACHE_VOLUME="${TRIVY_CACHE_VOLUME:-trivy-cache}"
REGISTRY_HOST="ghcr.io"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Prefer a trivy on PATH (that is what CI installs); otherwise run it from a
# container, so a local run needs nothing but docker.
TRIVY_BIN="$(command -v trivy 2>/dev/null || true)"
if [[ -z "${TRIVY_BIN}" ]]; then
  command -v docker >/dev/null 2>&1 || {
    echo "error: need either trivy on PATH or docker installed" >&2
    exit 1
  }
fi

if ! [[ "${MAX_ROWS}" =~ ^[0-9]+$ ]] || ((MAX_ROWS < 1)); then
  echo "error: MAX_ROWS must be a positive integer, got '${MAX_ROWS}'" >&2
  exit 1
fi

if [[ -z "${REPO:-}" ]]; then
  command -v gh >/dev/null 2>&1 || {
    echo "error: set REPO=owner/name, or install gh so it can be detected" >&2
    exit 1
  }
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

# Default to every image in the repo, so adding images/<name>/Dockerfile needs
# no change here.
if [[ -z "${IMAGES:-}" ]]; then
  IMAGES=""
  for dir in images/*/; do
    [[ -d "${dir}" ]] || continue
    IMAGES="${IMAGES} $(basename "${dir}")"
  done
fi
IMAGES="$(echo "${IMAGES}" | xargs)"

if [[ -z "${IMAGES}" ]]; then
  echo "error: no images found (run from the repo root, or set IMAGES)" >&2
  exit 1
fi

# Accept either separator, then work with a plain space-separated list.
PLATFORMS="$(echo "${PLATFORMS}" | tr ',' ' ' | xargs)"
if [[ -z "${PLATFORMS}" ]]; then
  echo "error: PLATFORMS is empty" >&2
  exit 1
fi

# Registry paths are lowercase; the repo owner may not be.
REPO_PATH="$(echo "${REPO}" | tr '[:upper:]' '[:lower:]')"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# run_trivy <args...>
#
# Writes trivy's stdout through untouched, so callers can capture the JSON
# report, whether trivy runs from PATH or from a container.
run_trivy() {
  if [[ -n "${TRIVY_BIN}" ]]; then
    "${TRIVY_BIN}" "$@"
    return
  fi

  local docker_args=(--rm -v "${TRIVY_CACHE_VOLUME}:/root/.cache")
  # Carry the host's registry credentials in, so a private package works the
  # same way it would with a trivy on PATH.
  [[ -d "${HOME}/.docker" ]] && docker_args+=(-v "${HOME}/.docker:/root/.docker:ro")

  docker run "${docker_args[@]}" "${TRIVY_IMAGE}" "$@"
}

TRIVY_VERSION="$(run_trivy --version 2>/dev/null | head -1 | awk '{print $2}')"
TRIVY_VERSION="${TRIVY_VERSION:-unknown}"
SCANNED_AT="$(date -u '+%Y-%m-%d %H:%M UTC')"

# jq needs the ignore list as an array.
IGNORE_JSON="$(printf '%s' "${IGNORE_PKGS}" | jq -Rc 'split(" ") | map(select(. != ""))')"

echo "Repo:      ${REPO}" >&2
echo "Images:    ${IMAGES}" >&2
echo "Tag:       ${TAG}" >&2
echo "Platforms: ${PLATFORMS}" >&2
echo "Trivy:     ${TRIVY_VERSION}" >&2

SUMMARY_ROWS=""
DETAIL_SECTIONS=""
SCAN_FAILURES=""
TOTAL_FIXABLE=0

for image in ${IMAGES}; do
  ref="${REGISTRY_HOST}/${REPO_PATH}/${image}:${TAG}"
  echo "==> ${ref}" >&2

  combined="${WORK_DIR}/${image}.jsonl"
  : >"${combined}"
  scanned_any=false

  for platform in ${PLATFORMS}; do
    raw="${WORK_DIR}/${image}-$(echo "${platform}" | tr '/' '-').json"

    if ! run_trivy image \
      --quiet \
      --scanners vuln \
      --format json \
      --timeout 10m \
      --platform "${platform}" \
      "${ref}" >"${raw}" 2>"${raw}.err"; then
      echo "    ! ${platform}: scan failed" >&2
      sed 's/^/      /' "${raw}.err" >&2 || true
      SCAN_FAILURES="${SCAN_FAILURES}- \`${image}\` on \`${platform}\`"$'\n'
      continue
    fi

    # Flatten to the fields the report needs, tagged with the platform, so the
    # per-platform reports can be merged into one deduplicated list below.
    jq -c --arg platform "${platform}" '
      [ .Results[]?
        | select(.Vulnerabilities)
        | .Vulnerabilities[]
        | { id: .VulnerabilityID,
            severity: .Severity,
            pkg: .PkgName,
            installed: (.InstalledVersion // ""),
            fixed: (.FixedVersion // ""),
            url: (.PrimaryURL // ""),
            platform: $platform }
      ]
    ' "${raw}" >>"${combined}"

    found="$(jq -r 'length' <<<"$(tail -1 "${combined}")")"
    echo "    ${platform}: ${found} finding(s)" >&2
    scanned_any=true
  done

  if [[ "${scanned_any}" != "true" ]]; then
    SUMMARY_ROWS="${SUMMARY_ROWS}| \`${image}\` | scan failed | - | - | - | - |"$'\n'
    continue
  fi

  merged="${WORK_DIR}/${image}-merged.json"
  jq -s 'add // []' "${combined}" >"${merged}"

  # One dedupe definition, reused by both passes below: the two architectures
  # install the same apt packages, so a finding present on both is one finding
  # that was seen on both, not two.
  # shellcheck disable=SC2016  # $g/$ignore are jq variables, not shell ones
  dedupe_def='
    def dedupe:
      group_by([.id, .pkg])
      | map(. as $g | $g[0] + { platforms: ($g | map(.platform) | unique | sort | join(", ")) });
    def actionable: dedupe | map(select(.pkg as $p | $ignore | index($p) | not));
    def held: dedupe | map(select(.pkg as $p | $ignore | index($p)));
    def serious: select(.severity == "CRITICAL" or .severity == "HIGH");
  '

  counts="$(jq -r --argjson ignore "${IGNORE_JSON}" "${dedupe_def}"'
    [ (actionable | map(serious | select(.fixed != "")) | length),
      (actionable | map(serious | select(.fixed == "")) | length),
      (actionable | map(select(.severity == "MEDIUM")) | length),
      (actionable | map(select(.severity == "LOW" or .severity == "UNKNOWN")) | length),
      (held | map(serious) | length)
    ] | @tsv
  ' "${merged}")"

  IFS=$'\t' read -r fixable unfixed medium low held <<<"${counts}"
  TOTAL_FIXABLE=$((TOTAL_FIXABLE + fixable))

  SUMMARY_ROWS="${SUMMARY_ROWS}| \`${image}\` | ${fixable} | ${unfixed} | ${medium} | ${low} | ${held} |"$'\n'

  # The detail table is the fixable HIGH/CRITICAL findings - the ones a package
  # upgrade or a base refresh would actually clear. Everything else is a count
  # above; tabling 5,000 MEDIUMs would make the report unreadable.
  rows="$(jq -r --argjson ignore "${IGNORE_JSON}" --argjson max "${MAX_ROWS}" "${dedupe_def}"'
    actionable
    | map(serious | select(.fixed != ""))
    | sort_by([(if .severity == "CRITICAL" then 0 else 1 end), .pkg, .id])
    | .[0:$max][]
    | "| [\(.id)](\(if .url == "" then "https://nvd.nist.gov/vuln/detail/" + .id else .url end)) "
      + "| \(.severity) | `\(.pkg)` | `\(.installed)` | `\(.fixed)` | \(.platforms) |"
  ' "${merged}")"

  section="### \`${image}\`"$'\n\n'
  if ((fixable == 0)); then
    section="${section}No fixable HIGH or CRITICAL findings."$'\n'
  else
    section="${section}| CVE | Severity | Package | Installed | Fixed in | Platforms |"$'\n'
    section="${section}| --- | -------- | ------- | --------- | -------- | --------- |"$'\n'
    section="${section}${rows}"$'\n'
    if ((fixable > MAX_ROWS)); then
      dropped=$((fixable - MAX_ROWS))
      section="${section}"$'\n'"_Showing ${MAX_ROWS} of ${fixable}; ${dropped} further fixable finding(s) not tabled. Raise \`MAX_ROWS\` to see them._"$'\n'
      echo "    note: tabled ${MAX_ROWS} of ${fixable} fixable findings (${dropped} not shown)" >&2
    fi
  fi

  DETAIL_SECTIONS="${DETAIL_SECTIONS}${section}"$'\n'
done

# ---------------------------------------------------------------------------
# The report itself, on stdout.
# ---------------------------------------------------------------------------
cat <<REPORT
## Container image vulnerability report

Scanned \`${REGISTRY_HOST}/${REPO_PATH}/<image>:${TAG}\` for ${PLATFORMS// /, } with Trivy ${TRIVY_VERSION} on ${SCANNED_AT}.

**${TOTAL_FIXABLE} fixable HIGH/CRITICAL finding(s)** across all images. This report is informational - no build or publish is gated on it.

| Image | Fixable HIGH/CRITICAL | Unfixed HIGH/CRITICAL | MEDIUM | LOW/UNKNOWN | Kernel headers (HIGH/CRITICAL) |
| ----- | --------------------- | --------------------- | ------ | ----------- | ------------------------------ |
${SUMMARY_ROWS}
${DETAIL_SECTIONS}
REPORT

if [[ -n "${SCAN_FAILURES}" ]]; then
  cat <<REPORT
### Scans that did not run

${SCAN_FAILURES}
The counts above are incomplete for these.
REPORT
fi

cat <<REPORT
---

**Fixable** means the package's distro has published a fixed version, so a
package upgrade or an upstream base refresh clears it. **Unfixed** means no fix
is available yet - tracked, not actionable here.

Findings are deduplicated across platforms on (CVE, package); the *Platforms*
column shows where each was seen.

*Kernel headers* counts findings in ${IGNORE_PKGS// /, }, held out of the other
columns. Ubuntu records every kernel CVE against that package, but it ships
header files rather than a kernel, and a container runs the host's kernel - so
those findings are not reachable in these images. Set \`IGNORE_PKGS=\` to fold
them back in.

Reproduce locally with \`make scan-images\`.
REPORT

if [[ -n "${SCAN_FAILURES}" ]]; then
  echo "One or more scans failed to run - the report is incomplete." >&2
  exit 1
fi
