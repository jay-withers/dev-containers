#!/usr/bin/env bash
# Prunes old image versions from the GitHub Container Registry, so the packages
# this repo publishes don't grow without bound: cd-weekly mints a new patch
# version every Monday, so each package would otherwise gain a version a week
# forever.
#
# What it keeps:
#   - the KEEP most recent release versions of each image (tags matching
#     vMAJOR.MINOR.PATCH), newest first by semver
#   - the throwaway `pr-<run_id>-<arch>` tags that ci-container-build pushes,
#     until they are PR_MAX_AGE_DAYS old. They are only needed for the minutes
#     between the base and leaf jobs of one CI run, but the age floor means a
#     prune that happens to land mid-run can't pull the base image out from
#     under a leaf job that is still building FROM it.
#   - every version carrying any other tag - `latest`, anything applied by
#     hand. Unrecognised tags are never touched.
#   - the untagged per-architecture child manifests of every kept version
#
# Everything else is deleted: release versions older than the KEEP most recent,
# expired PR tags, and untagged manifests that no kept version references (the
# per-architecture children of the versions being deleted, plus leftovers from
# publish runs that pushed by digest and then failed before merging a manifest).
#
# The untagged-children step is the part that matters. cd-publish pushes each
# architecture by digest with no tag and then merges those digests into one
# multi-arch manifest list, so every published version has two untagged
# children in GHCR that its tagged manifest points at. Deleting untagged
# versions indiscriminately - what most "clean up untagged images" recipes do -
# therefore breaks multi-arch manifests that are still tagged and in use. So
# the children of the kept versions are read back out of the registry and
# excluded, and if any of those manifests can't be read, untagged pruning is
# skipped for that image rather than guessed at.
#
# Deletion order is tagged versions first, then untagged, so a child is only
# removed after the index that referenced it is gone.
#
# Requires: gh (authenticated, with permission to delete the packages), jq,
# curl. In Actions, the repo's GITHUB_TOKEN with `packages: write` is enough
# for packages scoped to this repo. Note that GitHub refuses to delete any
# version of a public package once it has more than 5,000 downloads - that
# surfaces here as a delete failure, and can only be resolved via GitHub
# support.
#
# Usage:
#   ./scripts/prune-packages.sh
#
# Env overrides:
#   REPO             owner/name (default: current repo via gh)
#   KEEP             release versions to keep per image (default: 10)
#   PR_MAX_AGE_DAYS  age at which a CI pr-<run_id>-<arch> tag becomes prunable
#                    (default: 7)
#   IMAGES           space-separated image names (default: every directory in
#                    images/)
#   DRY_RUN          true to report what would be deleted without deleting it
#                    (default: false)

set -euo pipefail

KEEP="${KEEP:-10}"
PR_MAX_AGE_DAYS="${PR_MAX_AGE_DAYS:-7}"
DRY_RUN="${DRY_RUN:-false}"
REGISTRY_HOST="ghcr.io"
RELEASE_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
# ci-container-build tags the base image it pushes for the leaf jobs to build
# FROM as pr-<run_id>-<arch>.
PR_TAG_RE='^pr-[0-9]+-(amd64|arm64)$'

# Every manifest media type GHCR might answer with, so a single request handles
# both an index (multi-arch, has children) and a plain image manifest.
MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

for tool in gh jq curl; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "${tool} is required" >&2; exit 1; }
done

if ! [[ "${KEEP}" =~ ^[0-9]+$ ]] || ((KEEP < 1)); then
  echo "error: KEEP must be a positive integer, got '${KEEP}'" >&2
  exit 1
fi

if ! [[ "${PR_MAX_AGE_DAYS}" =~ ^[0-9]+$ ]]; then
  echo "error: PR_MAX_AGE_DAYS must be a non-negative integer, got '${PR_MAX_AGE_DAYS}'" >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

# The packages REST API is namespaced by owner type, and a personal account and
# an organisation use different paths for the same operation.
OWNER_TYPE="$(gh api "users/${OWNER}" --jq .type)"
if [[ "${OWNER_TYPE}" == "Organization" ]]; then
  OWNER_PATH="orgs/${OWNER}"
else
  OWNER_PATH="users/${OWNER}"
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

# Pull tokens for the registry are separate from the API token: GHCR issues a
# short-lived bearer token per repository scope, authenticated with the same
# credential (any username, token as the password). Public packages would work
# anonymously, but pass the credential so private ones work too.
API_TOKEN="$(gh auth token 2>/dev/null || true)"

echo "Repo:    ${REPO} (${OWNER_TYPE})"
echo "Images:  ${IMAGES}"
echo "Keep:    ${KEEP} most recent release versions per image"
echo "PR tags: pruned once ${PR_MAX_AGE_DAYS} day(s) old"
[[ "${DRY_RUN}" == "true" ]] && echo "Mode:    dry run - nothing will be deleted"

# Accumulated across all images, reported at the end.
DELETED=0
FAILURES=""

# collect_children <image_path> <digest> <token>
#
# Appends every manifest digest reachable from <digest> to CHILD_DIGESTS.
# Recursive because a per-architecture push can itself be an index (buildx
# attaches provenance/SBOM attestations as extra manifests), so children are
# not always one level down. SEEN_DIGESTS stops it revisiting shared layers of
# identical manifests. Plain newline-delimited strings rather than associative
# arrays, to stay compatible with the bash 3.2 that ships on macOS.
CHILD_DIGESTS=""
SEEN_DIGESTS=""
MANIFEST_ERRORS=0

collect_children() {
  local image_path="$1" digest="$2" token="$3"
  local body child

  case $'\n'"${SEEN_DIGESTS}" in
    *$'\n'"${digest}"$'\n'*) return 0 ;;
  esac
  SEEN_DIGESTS="${SEEN_DIGESTS}${digest}"$'\n'

  if ! body="$(curl -fsSL \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${MANIFEST_ACCEPT}" \
    "https://${REGISTRY_HOST}/v2/${image_path}/manifests/${digest}")"; then
    echo "    ! could not read manifest ${digest}" >&2
    MANIFEST_ERRORS=$((MANIFEST_ERRORS + 1))
    return 0
  fi

  while read -r child; do
    [[ -n "${child}" ]] || continue
    CHILD_DIGESTS="${CHILD_DIGESTS}${child}"$'\n'
    collect_children "${image_path}" "${child}" "${token}"
  done < <(jq -r '.manifests[]?.digest // empty' <<<"${body}")
}

# delete_version <versions_api_path> <id> <label>
delete_version() {
  local versions_path="$1" id="$2" label="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    would delete ${label}"
    return 0
  fi

  if gh api --method DELETE "${versions_path}/${id}" >/dev/null 2>&1; then
    echo "    deleted ${label}"
    DELETED=$((DELETED + 1))
  else
    echo "    ! failed to delete ${label}" >&2
    FAILURES="${FAILURES}    ${label}"$'\n'
  fi
}

for image in ${IMAGES}; do
  echo "==> ${REPO_NAME}/${image}"

  # The package name is "<repo>/<image>" and has to be path-encoded for the API.
  package_encoded="${REPO_NAME}%2F${image}"
  versions_path="${OWNER_PATH}/packages/container/${package_encoded}/versions"
  image_path="$(echo "${OWNER}/${REPO_NAME}/${image}" | tr '[:upper:]' '[:lower:]')"

  if ! versions_json="$(gh api --paginate "${versions_path}?per_page=100" --jq '.[]' | jq -sc '.')"; then
    echo "    cannot list versions - never published, or the token lacks package access; skipping"
    continue
  fi

  if [[ "$(jq 'length' <<<"${versions_json}")" -eq 0 ]]; then
    echo "    no versions - skipping"
    continue
  fi

  # The release tags to keep: newest KEEP by numeric semver order. Sorted in jq
  # rather than with sort -V so the ordering doesn't depend on which sort(1)
  # implementation is installed.
  keep_tags="$(jq -c --arg re "${RELEASE_RE}" --argjson keep "${KEEP}" '
    [.[] | .metadata.container.tags[]? | select(test($re))]
    | unique
    | map(ltrimstr("v") | split(".") | map(tonumber))
    | sort
    | reverse
    | .[0:$keep]
    | map("v" + (map(tostring) | join(".")))
  ' <<<"${versions_json}")"

  # Split every version into keep / delete / untagged. A tag is expendable if it
  # is a release tag outside the keep set, or a CI PR tag past PR_MAX_AGE_DAYS;
  # a version goes only when *every* tag it carries is expendable, since deleting
  # a version drops all of its tags at once (GHCR has no delete-a-single-tag
  # operation, and a PR build that happens to reproduce a release digest lands
  # both tags on one version). Anything else - `latest`, a fresh PR tag, a tag
  # applied by hand - keeps its version. Untagged versions are decided later,
  # once the kept versions' children are known.
  classified="$(jq -r \
    --arg re "${RELEASE_RE}" \
    --arg prre "${PR_TAG_RE}" \
    --argjson keeptags "${keep_tags}" \
    --argjson prdays "${PR_MAX_AGE_DAYS}" '
    .[]
    | . as $v
    | (.metadata.container.tags // []) as $tags
    # A missing created_at yields a negative age, so the version is treated as
    # too new to prune rather than deleted on a guess.
    | (if .created_at then ((now - (.created_at | fromdateiso8601)) / 86400) else -1 end) as $age
    | if ($tags | length) == 0 then
        "untagged\t\($v.id)\t\($v.name)\t"
      elif ($tags | all(
          (test($re) and (. as $t | $keeptags | index($t) | not))
          or (test($prre) and ($age > $prdays))
        )) then
        "delete\t\($v.id)\t\($v.name)\t\($tags | join(","))"
      else
        "keep\t\($v.id)\t\($v.name)\t\($tags | join(","))"
      end
  ' <<<"${versions_json}")"

  echo "    keeping releases: $(jq -r 'join(", ") | if . == "" then "(none)" else . end' <<<"${keep_tags}")"

  # Map the kept versions to the child manifests they reference, so those
  # children survive the untagged sweep.
  CHILD_DIGESTS=""
  SEEN_DIGESTS=""
  MANIFEST_ERRORS=0

  registry_token="$(curl -fsSL -u "x:${API_TOKEN}" \
    "https://${REGISTRY_HOST}/token?service=${REGISTRY_HOST}&scope=repository:${image_path}:pull" |
    jq -r '.token // empty')" || registry_token=""

  if [[ -z "${registry_token}" ]]; then
    echo "    ! could not get a registry pull token" >&2
    MANIFEST_ERRORS=$((MANIFEST_ERRORS + 1))
  else
    while IFS=$'\t' read -r kind id digest tags; do
      [[ "${kind}" == "keep" ]] || continue
      collect_children "${image_path}" "${digest}" "${registry_token}"
    done <<<"${classified}"
  fi

  # Tagged versions first: remove the index before the manifests it points at.
  while IFS=$'\t' read -r kind id digest tags; do
    [[ "${kind}" == "delete" ]] || continue
    delete_version "${versions_path}" "${id}" "${tags} (${digest})"
  done <<<"${classified}"

  if ((MANIFEST_ERRORS > 0)); then
    echo "    ! ${MANIFEST_ERRORS} manifest(s) unreadable - skipping untagged pruning for this image" >&2
    FAILURES="${FAILURES}    ${image}: could not resolve kept versions' children"$'\n'
    continue
  fi

  while IFS=$'\t' read -r kind id digest tags; do
    [[ "${kind}" == "untagged" ]] || continue
    case $'\n'"${CHILD_DIGESTS}" in
      *$'\n'"${digest}"$'\n'*) continue ;; # a kept version's child
    esac
    delete_version "${versions_path}" "${id}" "untagged ${digest}"
  done <<<"${classified}"
done

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry run complete - nothing was deleted."
else
  echo "Deleted ${DELETED} package version(s)."
fi

if [[ -n "${FAILURES}" ]]; then
  echo "The following could not be pruned:" >&2
  printf '%s' "${FAILURES}" >&2
  exit 1
fi
