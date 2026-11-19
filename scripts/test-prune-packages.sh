#!/usr/bin/env bash
# Tests scripts/prune-packages.sh end to end against stub `gh` and `curl`, so
# no network or credentials are needed. Covers how deletes are retried
# (cd-prune failed on 2026-11-16 with two versions left behind and no reason
# given):
#   - a delete that fails once (HTTP 502) is retried and succeeds
#   - a delete that answers HTTP 404 is already gone, not a failure
#   - a delete that keeps failing (HTTP 403) is reported with GitHub's error,
#     and the run exits non-zero
# and that a clean run exits zero.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/prune-packages.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/bin"

# Stub gh. Each version's DELETE behaviour comes from $WORK/behaviour/<id>:
#   ok       succeed
#   flaky    fail with HTTP 502 on the first attempt, then succeed
#   gone     HTTP 404
#   refused  HTTP 403 every time
# Every DELETE attempt is logged to $WORK/deletes.
cat >"${WORK}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "auth token") echo token; exit 0 ;;
esac
if [[ "$1" == "api" && "$2" == users/* ]]; then echo User; exit 0; fi
if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
  jq -c '.[]' "${STUB_WORK}/versions.json"; exit 0
fi
if [[ "$1" == "api" && "$2" == "--method" && "$3" == "DELETE" ]]; then
  id="${4##*/}"
  echo "${id}" >>"${STUB_WORK}/deletes"
  attempts="$(grep -cx "${id}" "${STUB_WORK}/deletes")"
  case "$(cat "${STUB_WORK}/behaviour/${id}")" in
    ok) exit 0 ;;
    flaky) ((attempts > 1)) && exit 0; echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1 ;;
    gone) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    refused) echo "gh: Forbidden (HTTP 403)" >&2; exit 1 ;;
  esac
fi
echo "unexpected gh call: $*" >&2
exit 2
STUB

# Stub curl: a registry token, and manifests with no children.
cat >"${WORK}/bin/curl" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  case "${arg}" in
    */token\?*) echo '{"token":"t"}'; exit 0 ;;
  esac
done
echo '{}'
STUB
chmod +x "${WORK}/bin/gh" "${WORK}/bin/curl"

FAILED=0

# run_case <name> <expected exit> <behaviours: id=behaviour ...> -- <expected output lines...>
#
# Four releases v1.0.0..v1.0.3 with ids 1..4 and KEEP=1, so ids 1-3 are deleted
# and id 4 is kept.
run_case() {
  local name="$1" want_rc="$2" rc=0 out pair line
  shift 2
  rm -rf "${WORK}/behaviour" "${WORK}/deletes"
  mkdir -p "${WORK}/behaviour"
  touch "${WORK}/deletes"
  while [[ "$1" != "--" ]]; do
    pair="$1"
    echo "${pair#*=}" >"${WORK}/behaviour/${pair%%=*}"
    shift
  done
  shift

  out="$(cd "${WORK}" && PATH="${WORK}/bin:${PATH}" STUB_WORK="${WORK}" \
    REPO=owner/repo IMAGES=img KEEP=1 DRY_RUN=false DELETE_RETRY_DELAYS=0 \
    "${SCRIPT}" 2>&1)" || rc=$?

  if [[ "${rc}" != "${want_rc}" ]]; then
    echo "FAIL ${name}: exit ${rc}, want ${want_rc}"
    FAILED=1
  fi
  for line in "$@"; do
    if ! grep -qF -- "${line}" <<<"${out}"; then
      echo "FAIL ${name}: output lacks: ${line}"
      FAILED=1
    fi
  done
  if [[ "${FAILED}" == 1 ]]; then
    printf '%s\n' "--- output of ${name}:" "${out}" "---"
  else
    echo "ok   ${name}"
  fi
}

jq -n '[range(0; 4) | {id: (. + 1), name: "sha256:d\(. + 1)",
  created_at: "2026-01-01T00:00:00Z",
  metadata: {container: {tags: ["v1.0.\(.)"]}}}]' >"${WORK}/versions.json"

run_case "transient failure is retried, 404 is already gone, a refusal fails the run" 1 \
  1=flaky 2=gone 3=refused -- \
  "deleted v1.0.0 (sha256:d1)" \
  "already gone v1.0.1 (sha256:d2)" \
  "! failed to delete v1.0.2 (sha256:d3): gh: Forbidden (HTTP 403)" \
  "Deleted 1 package version(s)." \
  "The following could not be pruned:"

if [[ "$(grep -cx 3 "${WORK}/deletes")" != 2 ]]; then
  echo "FAIL a refused delete is attempted once per DELETE_RETRY_DELAYS entry plus once: $(grep -cx 3 "${WORK}/deletes") attempts, want 2"
  FAILED=1
fi

run_case "clean run exits zero" 0 \
  1=ok 2=flaky 3=gone -- \
  "Deleted 2 package version(s)."

exit "${FAILED}"
