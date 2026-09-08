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
# The report is organised by *what would fix the finding*, because that is the
# only thing the reader can act on:
#
#   Fixable by a rebuild - findings in apt packages. The base image runs
#   apt-get upgrade, so the next publish clears them. This is the headline: it
#   is the bucket that can reach zero, and the one a human decides about.
#
#   Vendored in a pinned tool - findings in Go modules compiled into a
#   downloaded release binary, or in the Python and npm trees those tools ship
#   alongside themselves. Nothing in this repo patches those: the binary has to
#   be rebuilt by its author. Bumping the pinned URL helps only when the tool
#   has actually published a newer release, which Renovate already raises a PR
#   for. Counted and attributed per tool, deliberately out of the headline -
#   the useful signal there is *which tool* is carrying the risk, not a number
#   to drive to zero.
#
# Findings are attributed to the artifact that owns them rather than left as a
# bare package name: a "stdlib" finding is unactionable until you know it came
# from k9s. Trivy supplies this - the Result target is the binary path for a Go
# binary, and PkgPath locates the file for a Python or npm package - so the
# owner is derived, not maintained in a table here, and a new image or tool
# needs no change to this script.
#
# Detail tables are global, not per-image. Every image is built FROM base, so a
# per-image table repeats base's findings in each leaf and a per-image total
# counts them two or three times over; an *Images* column says the same thing
# once. Findings are deduplicated on (CVE, package, owner) - the same CVE in two
# different binaries is two things to fix, so the owner is part of the identity,
# but the same finding on both architectures is one finding seen twice.
#
# Each report ends with a machine-readable scan-state marker in an HTML comment,
# which GitHub does not render. Handed back as PREVIOUS_REPORT on the next run,
# it is what lets the report say what changed rather than restating the same
# totals every week - a weekly notification that reads identically whether or
# not anything moved is a notification nobody opens. The state travels inside
# the report itself, so no separate store has to be kept in step with it.
#
# Kernel headers are reported separately, not in the headline. Ubuntu's
# linux-libc-dev package carries the CVE record of every kernel fix, which on
# the current base is ~370 HIGH/CRITICAL findings - and every one is a header
# file. A container ships no kernel, so none of them is reachable; left in the
# headline they bury the handful of findings that are real. They are counted and
# called out, never silently dropped. IGNORE_PKGS holds the list.
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
#   MAX_ROWS     most detail rows to table in each section; the remainder is
#                reported as a count rather than dropped silently. The default
#                is set above the count these images actually carry, so a normal
#                run tables everything; it exists to stop a pathological result
#                set from producing an unreadable report (default: 200)
#   PREVIOUS_REPORT
#                path to the previous run's report. If it carries a scan-state
#                marker, the report gains a "changes since" section naming what
#                appeared and what cleared. Missing or unreadable is not an
#                error - the section is simply omitted.
#   DIGEST_FILE  path to write a short digest of the report to, in addition to
#                the full report on stdout. This is what a notification should
#                carry: the headline, what changed, and the per-image summary,
#                with the detail left in the full report. A mail client will
#                not collapse the full report's <details> blocks, so sending
#                that as a notification means posting every CVE table into an
#                inbox once a week.
#   META_FILE    path to write shell-sourceable KEY=value results to, for a
#                caller that has to decide something from them - notably
#                CHANGED (true/false/unknown), so a run that found nothing new
#                need not notify anybody.
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

# Shared jq vocabulary. `dedupe` collapses a finding seen on several platforms
# or in several images into one row that records where it was seen; the owner is
# part of the key because the same CVE in two different binaries needs two
# different upstream fixes.
# shellcheck disable=SC2016  # $ignore is a jq variable, not a shell one
JQ_DEFS='
  def dedupe:
    group_by([.id, .pkg, .owner])
    | map(.[0] + { platforms: (map(.platform) | unique | sort | join(", ")),
                   images:    (map(.image)    | unique | sort | join(", ")) });
  def kept:   map(select(.pkg as $p | $ignore | index($p) | not));
  def held:   map(select(.pkg as $p | $ignore | index($p)));
  def serious: select(.severity == "CRITICAL" or .severity == "HIGH");
  def fixable: select(.fixed != "");
  def sevrank: if .severity == "CRITICAL" then 0 else 1 end;
  def cvelink: "[\(.id)](\(if .url == "" then "https://nvd.nist.gov/vuln/detail/" + .id else .url end))";
  def detailrow: "| \(cvelink) | \(.severity) | `\(.pkg)` | `\(.installed)` | `\(.fixed)` | \(.images) | \(.platforms) |";
'

echo "Repo:      ${REPO}" >&2
echo "Images:    ${IMAGES}" >&2
echo "Tag:       ${TAG}" >&2
echo "Platforms: ${PLATFORMS}" >&2
echo "Trivy:     ${TRIVY_VERSION}" >&2

SUMMARY_ROWS=""
SCAN_FAILURES=""

# Every finding from every image and platform lands here, so the detail tables
# can be built once across the whole set rather than repeated per image.
ALL_FINDINGS="${WORK_DIR}/all.jsonl"
: >"${ALL_FINDINGS}"

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

    # Flatten to the fields the report needs, tagged with the image and
    # platform it came from, and attributed to the artifact that owns it:
    #
    #   os-pkgs        the distro itself - one owner for the whole apt set
    #   python / npm   the tree the package sits in, found via PkgPath: the
    #                  venv root for Python, the installed module for npm
    #   go binary      PkgPath is null for these, but the Result target is the
    #                  path of the binary the module was compiled into
    #
    # All three are read out of Trivy's own output, so this needs no per-tool
    # mapping and keeps working as images and tools are added.
    jq -c --arg platform "${platform}" --arg image "${image}" '
      [ .Results[]?
        | select(.Vulnerabilities)
        | .Class as $class | .Target as $target | .Type as $type
        | ((($target | capture("\\((?<d>[^)]+)\\)")?) // {d: $type}) | .d) as $distro
        | .Vulnerabilities[]
        | (.PkgPath // "") as $path
        | { id: .VulnerabilityID,
            severity: .Severity,
            pkg: .PkgName,
            installed: (.InstalledVersion // ""),
            fixed: (.FixedVersion // ""),
            url: (.PrimaryURL // ""),
            platform: $platform,
            image: $image,
            kind: (if $class == "os-pkgs" then "os" else "vendored" end),
            owner: (
              if $class == "os-pkgs" then "apt (" + $distro + ")"
              elif ($path | test("/site-packages/")) then
                "/" + ($path | sub("/lib/python[0-9.]*/site-packages/.*$"; ""))
              elif ($path | test("/node_modules/")) then
                "/" + ($path | capture("^(?<p>.*?/node_modules/[^/]+)") | .p)
              else "/" + $target end) }
      ]
    ' "${raw}" >>"${combined}"

    found="$(jq -r 'length' <<<"$(tail -1 "${combined}")")"
    echo "    ${platform}: ${found} finding(s)" >&2
    scanned_any=true
  done

  if [[ "${scanned_any}" != "true" ]]; then
    SUMMARY_ROWS="${SUMMARY_ROWS}| \`${image}\` | scan failed | - | - | - | - | - |"$'\n'
    continue
  fi

  cat "${combined}" >>"${ALL_FINDINGS}"

  merged="${WORK_DIR}/${image}-merged.json"
  jq -s 'add // []' "${combined}" >"${merged}"

  # Per-image counts, deduplicated within the image so the two architectures do
  # not double every number. These stay per-image because "which image is worst"
  # is a real question; the detail tables below are global.
  counts="$(jq -r --argjson ignore "${IGNORE_JSON}" "${JQ_DEFS}"'
    dedupe
    | [ (kept | map(select(.kind == "os")       | serious | fixable | .id) | unique | length),
        (kept | map(select(.kind == "vendored") | serious | fixable) | length),
        (kept | map(serious | select(.fixed == "")) | length),
        (kept | map(select(.severity == "MEDIUM")) | length),
        (kept | map(select(.severity == "LOW" or .severity == "UNKNOWN")) | length),
        (held | map(serious) | length)
      ] | @tsv
  ' "${merged}")"

  IFS=$'\t' read -r os_fix vendored_fix unfixed medium low held <<<"${counts}"

  SUMMARY_ROWS="${SUMMARY_ROWS}| \`${image}\` | ${os_fix} | ${vendored_fix} | ${unfixed} | ${medium} | ${low} | ${held} |"$'\n'
done

# ---------------------------------------------------------------------------
# Global aggregation: one deduplicated view across every image and platform.
# ---------------------------------------------------------------------------
ALL_MERGED="${WORK_DIR}/all-merged.json"
jq -s 'add // []' "${ALL_FINDINGS}" >"${ALL_MERGED}"

read -r OS_TOTAL VENDORED_TOTAL VENDORED_OWNERS <<<"$(
  jq -r --argjson ignore "${IGNORE_JSON}" "${JQ_DEFS}"'
    dedupe | kept | map(serious | fixable) as $f
    | [ ($f | map(select(.kind == "os") | .id)  | unique | length),
        ($f | map(select(.kind == "vendored")) | length),
        ($f | map(select(.kind == "vendored") | .owner) | unique | length)
      ] | @tsv
  ' "${ALL_MERGED}"
)"

# The rebuild bucket: apt packages with a published fix. This is the section a
# reader can act on, so it leads.
# One row per CVE, not per package: a single gnupg advisory is recorded against
# every binary package the source produces, and ten rows saying "apt upgrade"
# read no differently from one.
OS_ROWS="$(jq -r --argjson ignore "${IGNORE_JSON}" --argjson max "${MAX_ROWS}" "${JQ_DEFS}"'
  dedupe | kept | map(select(.kind == "os") | serious | fixable)
  | group_by([.id, .installed, .fixed])
  | map(.[0] + { pkgs:   (map(.pkg) | unique | sort),
                 images: (map(.images) | join(", ") | split(", ") | unique | sort | join(", ")) })
  | sort_by([sevrank, (.pkgs | first), .id])
  | .[0:$max][]
  | "| \(cvelink) | \(.severity) | \(.pkgs | map("`" + . + "`") | join(", ")) "
    + "| `\(.installed)` | `\(.fixed)` | \(.images) | \(.platforms) |"
' "${ALL_MERGED}")"

# The upstream bucket, grouped by the artifact that carries it. One row per
# tool, with the findings themselves folded into a collapsed block - the count
# and the name are the signal, the CVE list is reference.
VENDORED_SUMMARY="$(jq -r --argjson ignore "${IGNORE_JSON}" "${JQ_DEFS}"'
  dedupe | kept | map(select(.kind == "vendored") | serious | fixable)
  | group_by(.owner)
  | map({ owner: .[0].owner,
          images: (map(.images) | join(", ") | split(", ") | unique | sort | join(", ")),
          n: length,
          pkgs: (map(.pkg) | unique | sort) })
  | sort_by(-.n)
  | .[]
  | "| `\(.owner)` | \(.images) | \(.n) | \(.pkgs | map("`" + . + "`") | join(", ")) |"
' "${ALL_MERGED}")"

VENDORED_DETAIL="$(jq -r --argjson ignore "${IGNORE_JSON}" --argjson max "${MAX_ROWS}" "${JQ_DEFS}"'
  dedupe | kept | map(select(.kind == "vendored") | serious | fixable)
  | group_by(.owner)
  | sort_by(-length)
  | .[]
  | ( "<details><summary><code>\(.[0].owner)</code> — \(length) finding(s)</summary>\n",
      "| CVE | Severity | Package | Installed | Fixed in | Images | Platforms |",
      "| --- | -------- | ------- | --------- | -------- | ------ | --------- |",
      ( sort_by([sevrank, .pkg, .id]) | .[0:$max][] | detailrow ),
      "\n</details>\n" )
' "${ALL_MERGED}")"

# The scan-state marker: every fixable HIGH/CRITICAL finding as bucket|CVE|owner.
# CVE and owner together, because the same CVE arriving in a second tool is news.
STATE_NOW="$(jq -c --argjson ignore "${IGNORE_JSON}" "${JQ_DEFS}"'
  dedupe | kept | map(serious | fixable | (.kind + "|" + .id + "|" + .owner)) | unique
' "${ALL_MERGED}")"

DELTA_SECTION=""
DELTA_DIGEST=""
STATE_PREV=""
NEW_COUNT=0
CLEARED_COUNT=0
# unknown means "no baseline to compare against", which is not the same as
# "nothing changed" - a caller deciding whether to notify has to tell them
# apart, or the very first run would go out silently.
CHANGED="unknown"

if [[ -n "${PREVIOUS_REPORT:-}" && -r "${PREVIOUS_REPORT}" ]]; then
  STATE_PREV="$(sed -n 's/^<!-- scan-state:\(.*\) -->$/\1/p' "${PREVIOUS_REPORT}" | tail -1)"
  # A previous report that predates this marker, or one truncated before it,
  # leaves this empty - which means no comparison, not a broken report.
  if [[ -n "${STATE_PREV}" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"${STATE_PREV}"; then
    read -r NEW_COUNT CLEARED_COUNT <<<"$(
      jq -r --argjson now "${STATE_NOW}" '[(($now - .) | length), ((. - $now) | length)] | @tsv' <<<"${STATE_PREV}"
    )"
    CHANGED=$( ((NEW_COUNT + CLEARED_COUNT > 0)) && echo true || echo false )

    # $limit rows in the full report, a shorter list in the digest: the digest
    # is read in an inbox, where a hundred-line list is the same as no list.
    delta_md() {
      jq -r --argjson now "${STATE_NOW}" --argjson limit "$1" '
        . as $prev
        | (($now - $prev) | sort) as $new
        | (($prev - $now) | sort) as $gone
        | def render($list):
            ($list | map(split("|") | "- \(.[1]) in `\(.[2])`") | .[0:$limit] | join("\n"))
            + (if ($list | length) > $limit then "\n- _…and \(($list | length) - $limit) more_" else "" end);
          "### Changes since the last report\n\n"
        + "**\($new | length) new**, **\($gone | length) cleared**.\n\n"
        + (if ($new  | length) > 0 then "New:\n\n"     + render($new)  + "\n\n" else "" end)
        + (if ($gone | length) > 0 then "Cleared:\n\n" + render($gone) + "\n\n" else "" end)
      ' <<<"${STATE_PREV}"
    }
    DELTA_SECTION="$(delta_md 20)"
    DELTA_DIGEST="$(delta_md 5)"
    echo "delta: ${NEW_COUNT} new, ${CLEARED_COUNT} cleared" >&2
  fi
fi

if [[ -z "${DELTA_SECTION}" ]]; then
  DELTA_SECTION="### Changes since the last report"$'\n\n'"No previous report to compare against - this is the baseline."$'\n'
  DELTA_DIGEST="${DELTA_SECTION}"
fi

if ((OS_TOTAL > MAX_ROWS)); then
  OS_ROWS="${OS_ROWS}"$'\n'"_Showing ${MAX_ROWS} of ${OS_TOTAL}. Raise \`MAX_ROWS\` to see the rest._"
  echo "note: tabled ${MAX_ROWS} of ${OS_TOTAL} rebuild-fixable findings" >&2
fi

# ---------------------------------------------------------------------------
# The digest and the machine-readable results, for a caller that notifies.
# ---------------------------------------------------------------------------
HEADLINE="**${OS_TOTAL} HIGH/CRITICAL CVE(s) in apt packages clear on the next rebuild.**"

if [[ -n "${DIGEST_FILE:-}" ]]; then
  cat >"${DIGEST_FILE}" <<DIGEST
## Container image vulnerability report

\`${REGISTRY_HOST}/${REPO_PATH}/<image>:${TAG}\` - ${PLATFORMS// /, } - Trivy ${TRIVY_VERSION} - ${SCANNED_AT}

${HEADLINE}
A further ${VENDORED_TOTAL} finding(s) are vendored inside ${VENDORED_OWNERS} pinned tool release(s) and
clear only when those tools publish new releases.

${DELTA_DIGEST}

| Image | Rebuild clears (CVEs) | Vendored (upstream) | Unfixed | MEDIUM | LOW/UNKNOWN | Kernel headers |
| ----- | --------------------- | ------------------- | ------- | ------ | ----------- | -------------- |
${SUMMARY_ROWS}
DIGEST

  if [[ -n "${SCAN_FAILURES}" ]]; then
    cat >>"${DIGEST_FILE}" <<DIGEST
**Some scans did not run, so these counts are incomplete:**

${SCAN_FAILURES}
DIGEST
  fi

  echo "digest: ${DIGEST_FILE}" >&2
fi

if [[ -n "${META_FILE:-}" ]]; then
  {
    echo "OS_TOTAL=${OS_TOTAL}"
    echo "VENDORED_TOTAL=${VENDORED_TOTAL}"
    echo "VENDORED_OWNERS=${VENDORED_OWNERS}"
    echo "NEW_COUNT=${NEW_COUNT}"
    echo "CLEARED_COUNT=${CLEARED_COUNT}"
    echo "CHANGED=${CHANGED}"
    echo "SCAN_FAILED=$(if [[ -n "${SCAN_FAILURES}" ]]; then echo true; else echo false; fi)"
  } >"${META_FILE}"
  echo "meta: ${META_FILE}" >&2
fi

# ---------------------------------------------------------------------------
# The report itself, on stdout.
# ---------------------------------------------------------------------------
cat <<REPORT
## Container image vulnerability report

Scanned \`${REGISTRY_HOST}/${REPO_PATH}/<image>:${TAG}\` for ${PLATFORMS// /, } with Trivy ${TRIVY_VERSION} on ${SCANNED_AT}.

${HEADLINE} A further
${VENDORED_TOTAL} are vendored inside ${VENDORED_OWNERS} pinned tool release(s) and clear only when
those tools publish new releases. This report is informational - no build or
publish is gated on it.

| Image | Rebuild clears (CVEs) | Vendored (upstream) | Unfixed | MEDIUM | LOW/UNKNOWN | Kernel headers |
| ----- | --------------------- | ------------------- | ------- | ------ | ----------- | -------------- |
${SUMMARY_ROWS}
${DELTA_SECTION}
REPORT

cat <<REPORT
### Fixable by a rebuild

Findings in apt packages. \`images/base/Dockerfile\` runs \`apt-get upgrade\`, so
publishing a new version clears these - \`cd-weekly\` does that every Monday.

REPORT

if ((OS_TOTAL == 0)); then
  echo "None. Every apt package with a published fix is already current in these images."
  echo
else
  cat <<REPORT
| CVE | Severity | Packages | Installed | Fixed in | Images | Platforms |
| --- | -------- | -------- | --------- | -------- | ------ | --------- |
${OS_ROWS}

REPORT
fi

cat <<REPORT
### Vendored in pinned tool releases

Findings in code compiled or bundled into a downloaded release artifact - Go
modules linked into a binary, or the Python and npm trees a tool ships with
itself. Nothing here patches those: the artifact has to be rebuilt by its
author. Bumping the pinned URL helps only if the tool has published a newer
release, and Renovate already raises that PR. What this section is for is
naming *which* tool is carrying the risk, so a tool that stays vulnerable for
long enough becomes a decision about whether to keep depending on it.

REPORT

if ((VENDORED_TOTAL == 0)); then
  echo "None."
  echo
else
  cat <<REPORT
| Tool | Images | HIGH/CRITICAL | Packages |
| ---- | ------ | ------------- | -------- |
${VENDORED_SUMMARY}

${VENDORED_DETAIL}
REPORT
fi

if [[ -n "${SCAN_FAILURES}" ]]; then
  cat <<REPORT
### Scans that did not run

${SCAN_FAILURES}
The counts above are incomplete for these.

REPORT
fi

cat <<REPORT
---

Findings are deduplicated on (CVE, package, owner) across every image and
platform scanned, and the *Images* and *Platforms* columns say where each was
seen. Every image is built \`FROM\` base, so listing each leaf separately would
repeat base's findings two or three times and inflate any total taken across
them; the per-image columns above are deduplicated within each image.

**Unfixed** counts HIGH/CRITICAL findings with no published fix anywhere -
tracked, not actionable by anyone yet.

*Kernel headers* counts findings in ${IGNORE_PKGS// /, }, held out of the other
columns. Ubuntu records every kernel CVE against that package, but it ships
header files rather than a kernel, and a container runs the host's kernel - so
those findings are not reachable in these images. Set \`IGNORE_PKGS=\` to fold
them back in.

Reproduce locally with \`make scan-images\`.

<!-- scan-state:${STATE_NOW} -->
REPORT

if [[ -n "${SCAN_FAILURES}" ]]; then
  echo "One or more scans failed to run - the report is incomplete." >&2
  exit 1
fi
