#!/usr/bin/env bash
# One-time GitHub settings for this repo - the parts that can't live as files
# in the repo:
#   - repository auto-merge + delete-branch-on-merge (auto-merge is what lets
#     renovate.json's platformAutomerge actually merge PRs)
#   - a ruleset on the target branch requiring PR approval and the given CI
#     status checks, with the repo owner (admin role) and the Renovate app
#     exempted as bypass actors on both
#
# Deletes every ruleset currently on the repo before creating this one, so
# the repo always ends up with exactly the state this script defines rather
# than accumulating stale rulesets from earlier runs or manual changes made
# in the GitHub UI.
#
# Requires: gh CLI, authenticated with admin rights on the target repo.
#
# Usage:
#   ./scripts/protect-branch.sh [branch] [required-check-contexts]
#
# required-check-contexts is a NEWLINE-separated list of status check context
# names (newline, not space, because a context name can itself contain spaces
# - see below), defaulting to this repo's single check:
# "pre-commit / Pre-commit".
#
# Check names must match the context a job reports on a PR, not just its job
# id. The ci-pre-commit workflow's `pre-commit` job calls a reusable workflow,
# so the context it reports is "<caller job id> / <reusable job name>" =
# "pre-commit / Pre-commit", NOT the bare "pre-commit" - requiring the bare
# name leaves the check "Expected" forever. Add your own checks (comma/newline
# separated) as you add CI workflows. Confirm exact names with: gh pr checks
#
# Env overrides:
#   REPO               owner/name (default: current repo via gh)
#   APPROVALS_REQUIRED number of required approving reviews
#                      (default: 1 for org-owned repos, 0 for user-owned repos
#                      - see the bypass_actors note below)
#
# GitHub only honours ruleset bypass_actors (the Renovate app entry below)
# on repos owned by an organisation. On a personal (User-owned) repo, that
# entry is accepted by the API but silently has no effect: Renovate's
# platformAutomerge enables auto-merge, but the required-review rule still
# blocks it forever, since Renovate can't review its own PR and nothing else
# is exempted. There's no fix that keeps required reviews on a personal repo
# short of installing a separate auto-approve app (e.g. Mend's
# renovate-approve), so this script defaults required reviews to 0 there
# instead - status checks are still required and direct pushes to the branch
# are still blocked, only the "someone else must approve" step is dropped.
# This is a reasonable default even for public repos: merge/auto-merge is
# already gated by write access, which forks and outside contributors don't
# have, so dropping the approval count doesn't hand out any new capability -
# it only removes friction for pushers who already had it.

set -euo pipefail

BRANCH="${1:-main}"
REQUIRED_CHECKS="${2:-pre-commit / Pre-commit}"
RULESET_NAME="Protect ${BRANCH}"

command -v gh >/dev/null 2>&1 || { echo "gh CLI is required" >&2; exit 1; }

if [[ -z "${REQUIRED_CHECKS}" ]]; then
  echo "error: required-check-contexts must not be empty" >&2
  echo "usage: ./scripts/protect-branch.sh [branch] '<check1>' (one context per line)" >&2
  echo "       e.g. ./scripts/protect-branch.sh main 'pre-commit / Pre-commit'" >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
OWNER="${REPO%%/*}"
OWNER_TYPE="$(gh api "users/${OWNER}" --jq .type)"

if [[ "${OWNER_TYPE}" == "Organization" ]]; then
  DEFAULT_APPROVALS_REQUIRED=1
else
  DEFAULT_APPROVALS_REQUIRED=0
  echo "Note: ${OWNER} is a user account, not an organisation - ruleset"
  echo "      bypass_actors (including the Renovate app) have no effect here,"
  echo "      so required approving reviews defaults to 0. Override with"
  echo "      APPROVALS_REQUIRED=<n> if you add other collaborators and want"
  echo "      human review enforced (Renovate's own PRs will then need an"
  echo "      auto-approve app, e.g. renovate-approve, to ever merge)."
fi
APPROVALS_REQUIRED="${APPROVALS_REQUIRED:-${DEFAULT_APPROVALS_REQUIRED}}"

echo "Repo:    ${REPO} (${OWNER_TYPE})"
echo "Branch:  ${BRANCH}"
echo "Checks:  ${REQUIRED_CHECKS}"
echo "Reviews: ${APPROVALS_REQUIRED} required"

echo "==> Enabling repository auto-merge and merged-branch cleanup"
gh api -X PATCH "repos/${REPO}" -f allow_auto_merge=true -F delete_branch_on_merge=true >/dev/null

# Split on newlines, not spaces: a context name can contain spaces (e.g. the
# reusable-workflow context "pre-commit / Pre-commit"). read -d '' with a
# newline IFS is portable to macOS's bash 3.2 (mapfile is bash 4+).
IFS=$'\n' read -rd '' -a REQUIRED_CHECKS_ARR <<<"${REQUIRED_CHECKS}" || true
REQUIRED_CHECKS_JSON="$(jq -nc '$ARGS.positional | map({context: .})' --args -- "${REQUIRED_CHECKS_ARR[@]}")"

echo "Looking up the Renovate GitHub App id..."
RENOVATE_APP_ID="$(gh api apps/renovate --jq .id)"
echo "Renovate app id: ${RENOVATE_APP_ID}"

# Built-in RepositoryRole ids used by the rulesets API (GitHub-defined, fixed):
# read=1 triage=2 write=3 maintain=4 admin=5
ADMIN_ROLE_ID=5

PAYLOAD="$(cat <<JSON
{
  "name": "${RULESET_NAME}",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/${BRANCH}"],
      "exclude": []
    }
  },
  "bypass_actors": [
    { "actor_id": ${RENOVATE_APP_ID}, "actor_type": "Integration", "bypass_mode": "always" },
    { "actor_id": ${ADMIN_ROLE_ID}, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "rules": [
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": ${APPROVALS_REQUIRED},
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "required_status_checks": ${REQUIRED_CHECKS_JSON},
        "strict_required_status_checks_policy": true
      }
    }
  ]
}
JSON
)"

echo "==> Clearing existing rulesets"
gh api "repos/${REPO}/rulesets" --jq '.[] | "\(.id) \(.name)"' | while read -r id name; do
  echo "    deleting '${name}' (id ${id})"
  gh api --method DELETE "repos/${REPO}/rulesets/${id}" >/dev/null
done

echo "==> Creating ruleset '${RULESET_NAME}'"
gh api --method POST "repos/${REPO}/rulesets" --input - <<<"${PAYLOAD}" >/dev/null

echo "Done. Verify at: https://github.com/${REPO}/settings/rules"
