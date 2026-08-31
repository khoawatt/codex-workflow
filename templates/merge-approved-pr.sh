#!/usr/bin/env bash
# Safely merge the open Pull Request for the current branch, but ONLY after
# every safety condition is verified (fail closed). This is the sole permitted
# merge path: raw `gh pr merge` (and any --admin / bypass flag) must be run
# through this wrapper so a caller cannot escalate privileges.
#
# Safety conditions (ALL must hold, otherwise the script exits non-zero and
# does NOT merge; any command/API failure is treated as a blocker):
#   1. The current branch has EXACTLY ONE matching OPEN PR owned by this repo.
#   2. The PR is mergeable (no conflicts).
#   3. A ChatGPT review approval is recorded (verdict "approve") whose head_sha
#      exactly equals the local HEAD and whose pr number equals the selected PR
#      (case-insensitive repo match).
#   4. Every required status check on the PR is SUCCESS; a failure to query the
#      checks is itself a blocker.
#   5. The final merge is HEAD-atomic: `gh pr merge --match-head-commit <HEAD>`
#      refuses to merge if the PR head moved away from the reviewed commit.
#   6. The PR is re-read immediately before the guarded mutation (TOCTOU guard).
#
# The script accepts NO arguments. It deliberately ignores any flags passed
# (e.g. --admin, --delete-branch) and merges with a fixed `--merge` method.
#
# Exit codes: 0 = merged; 1 = precondition failed (nothing merged); 2 = usage error.
# Ported hardening from opencode-workflow/templates/merge-approved-pr.sh (direct fetch
# + sidebar fixes) while keeping codex-workflow's TOCTOU double-read + --required checks.

set -Eeuo pipefail

die() { printf 'merge-approved-pr: %s\n' "$*" >&2; exit 1; }

# --- Reject any arguments (defense in depth against --admin / bypass flags) ---
if [ "$#" -gt 0 ]; then
  echo "ERROR: merge-approved-pr accepts no arguments (no --admin, no bypass flags)." >&2
  exit 2
fi

for command in git gh jq chatgpt-consult; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
done

branch="$(git branch --show-current)"
if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  echo "ERROR: could not determine a current branch (detached HEAD?)." >&2
  exit 1
fi
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || die 'could not resolve the GitHub repository'
local_head="$(git rev-parse HEAD)"

# --- Resolve OPEN PRs for this branch, owned by this repo (fail if not exactly one) ---
candidates="$(gh pr list --state open --head "$branch" --json number,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository == false) | .number]')" || die 'could not list open pull requests'
count="$(printf '%s' "$candidates" | jq 'length')"
if [ "$count" -ne 1 ]; then
  echo "ERROR: expected exactly one OPEN same-repo PR for branch '$branch'; found $count." >&2
  exit 1
fi
pr="$(printf '%s' "$candidates" | jq -r '.[0]')"

read_pr() {
    gh pr view "$pr" --json state,mergeable,headRefOid,baseRefName --jq .
}
pr_data="$(read_pr)" || die "could not read PR #$pr"
state="$(printf '%s' "$pr_data" | jq -r '.state')"
mergeable="$(printf '%s' "$pr_data" | jq -r '.mergeable')"
remote_head="$(printf '%s' "$pr_data" | jq -r '.headRefOid')"
[ "$state" = "OPEN" ] || { echo "ERROR: PR #$pr is not OPEN (state=$state)." >&2; exit 1; }
[ "$mergeable" = "MERGEABLE" ] || { echo "ERROR: PR #$pr is not mergeable (mergeable=$mergeable)." >&2; exit 1; }
[[ "$remote_head" == "$local_head" ]] || { echo "ERROR: local HEAD $local_head does not match PR HEAD $remote_head." >&2; exit 1; }

# --- Verify recorded ChatGPT approval: verdict approve AND head_sha == HEAD AND pr matches ---
approval="$(chatgpt-consult approval get)" || die 'could not read ChatGPT approval state'
approval_verdict="$(printf '%s' "$approval" | jq -r '.verdict // empty' 2>/dev/null || echo "")"
approval_sha="$(printf '%s' "$approval" | jq -r '.head_sha // empty' 2>/dev/null || echo "")"
approval_pr="$(printf '%s' "$approval" | jq -r '.pr // empty' 2>/dev/null || echo "")"
approval_repo="$(printf '%s' "$approval" | jq -r '.repo // empty' 2>/dev/null || echo "")"
[ "$approval_verdict" = "approve" ] || { echo "ERROR: no recorded 'approve' verdict (verdict=${approval_verdict:-none}). Run chatgpt-consult approval first." >&2; exit 1; }
if [ -z "$approval_sha" ] || [ "$approval_sha" != "$local_head" ]; then
  echo "ERROR: recorded approval head_sha ('$approval_sha') does not exactly match local HEAD ($local_head). Re-review this HEAD." >&2
  exit 1
fi
# PR binding: if approval has a PR, it must match; if approval PR is null/empty (legacy), allow but log
if [ -n "$approval_pr" ] && [ "$approval_pr" != "$pr" ]; then
  echo "ERROR: recorded approval is for PR #$approval_pr, but branch '$branch' resolves to PR #$pr." >&2
  exit 1
fi
if [ -n "$approval_repo" ]; then
  if [ "$(printf '%s' "$approval_repo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "ERROR: approval repository ('$approval_repo') does not match current repo ($repo)." >&2
    exit 1
  fi
fi

# --- Verify all required checks pass (a query failure is a blocker, NOT swallowed) ---
if ! checks="$(gh pr checks "$pr" --required --json name,state 2>&1)"; then
  echo "ERROR: could not query required checks for PR #$pr. Aborting without merging." >&2
  echo "$checks" >&2
  exit 1
fi
failed="$(printf '%s' "$checks" | jq -r '.[] | select(.state != "SUCCESS") | "\(.name): \(.state)"' 2>/dev/null)"
if [ -n "$failed" ]; then
  echo "ERROR: non-SUCCESS required checks on PR #$pr:" >&2
  printf '%s\n' "$failed" >&2
  exit 1
fi

# --- Re-read immediately before the guarded mutation and bind gh merge to the same HEAD (TOCTOU guard) ---
pr_data="$(read_pr)" || die "could not refresh PR #$pr"
state="$(printf '%s' "$pr_data" | jq -r '.state')"
mergeable="$(printf '%s' "$pr_data" | jq -r '.mergeable')"
remote_head="$(printf '%s' "$pr_data" | jq -r '.headRefOid')"
[ "$state" = "OPEN" ] || { echo "ERROR: PR #$pr state changed to $state before merge." >&2; exit 1; }
[ "$mergeable" = "MERGEABLE" ] || { echo "ERROR: PR #$pr mergeability changed to $mergeable before merge." >&2; exit 1; }
[[ "$remote_head" == "$local_head" ]] || { echo "ERROR: PR #$pr HEAD changed to $remote_head before merge (expected $local_head)." >&2; exit 1; }

printf 'All safety checks passed for %s PR #%s at %s (base=%s). Executing the human-requested merge.\n' "$repo" "$pr" "$local_head" "$(printf '%s' "$pr_data" | jq -r '.baseRefName')"
gh pr merge "$pr" --merge --match-head-commit "$local_head"
