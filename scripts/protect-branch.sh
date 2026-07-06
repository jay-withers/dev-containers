#!/usr/bin/env bash
# Apply a repository ruleset that protects a branch:
#   - requires PR approval before merge
#   - requires the CI status check to pass
#   - lets the repo owner (admin role) and the Renovate app bypass both
#
# Requires: gh CLI, authenticated with admin rights on the target repo.
#
# Usage:
#   ./scripts/protect-branch.sh [branch] [required-check-context]
#
# Env overrides:
#   REPO               owner/name (default: current repo via gh)
#   APPROVALS_REQUIRED number of required approving reviews (default: 1)

set -euo pipefail

BRANCH="${1:-main}"
REQUIRED_CHECK="${2:-pre-commit / Pre-commit}"
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
APPROVALS_REQUIRED="${APPROVALS_REQUIRED:-1}"
RULESET_NAME="Protect ${BRANCH}"

command -v gh >/dev/null 2>&1 || { echo "gh CLI is required" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }

echo "Repo:   ${REPO}"
echo "Branch: ${BRANCH}"
echo "Check:  ${REQUIRED_CHECK}"

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
        "required_status_checks": [
          { "context": "${REQUIRED_CHECK}" }
        ],
        "strict_required_status_checks_policy": true
      }
    }
  ]
}
JSON
)"

EXISTING_ID="$(gh api "repos/${REPO}/rulesets" --jq ".[] | select(.name == \"${RULESET_NAME}\") | .id" || true)"

if [[ -n "${EXISTING_ID}" ]]; then
  echo "Updating existing ruleset (id ${EXISTING_ID})..."
  gh api --method PUT "repos/${REPO}/rulesets/${EXISTING_ID}" --input - <<<"${PAYLOAD}" >/dev/null
else
  echo "Creating new ruleset..."
  gh api --method POST "repos/${REPO}/rulesets" --input - <<<"${PAYLOAD}" >/dev/null
fi

echo "Done. Verify at: https://github.com/${REPO}/settings/rules"
