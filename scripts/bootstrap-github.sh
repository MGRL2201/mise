#!/usr/bin/env bash
# Idempotent GitHub setup for mise: repo, branches, protection, labels,
# milestones, issues. Safe to rerun: skips anything that already exists.
# Requires: gh (authenticated), run from repo root with main + develop committed.
set -euo pipefail

REPO_NAME=mise
gh auth status >/dev/null
OWNER=$(gh api user -q .login)
REPO="$OWNER/$REPO_NAME"

# --- repo + branches ---------------------------------------------------------
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO_NAME" --public --source . --remote origin
fi
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
git push -u origin main develop
gh repo edit "$REPO" --default-branch develop

# --- branch protection (classic endpoint) ------------------------------------
for b in main develop; do
  gh api -X PUT "repos/$REPO/branches/$b/protection" --input - >/dev/null <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
  echo "== protection read-back: $b"
  gh api "repos/$REPO/branches/$b/protection" -q '{
    enforce_admins: .enforce_admins.enabled,
    approvals: .required_pull_request_reviews.required_approving_review_count,
    dismiss_stale: .required_pull_request_reviews.dismiss_stale_reviews,
    force_pushes: .allow_force_pushes.enabled,
    deletions: .allow_deletions.enabled}'
done

# --- labels (--force = create or update) --------------------------------------
for m in foundation tasks calendar finance notes news today sync widgets mac; do
  gh label create "module:$m" --repo "$REPO" --color 1d76db --force >/dev/null
done
gh label create feature       --repo "$REPO" --color 0e8a16 --force >/dev/null
gh label create spike         --repo "$REPO" --color fbca04 --description "Time-boxed feasibility check" --force >/dev/null
gh label create infra         --repo "$REPO" --color 5319e7 --force >/dev/null
gh label create priority:high --repo "$REPO" --color d93f0b --force >/dev/null

# --- milestones -----------------------------------------------------------------
M1="Phase 1: Foundation & spikes"
M2="Phase 2: Tasks & Calendar"
M3="Phase 3: Finance core"
M4="Phase 4: Finance imports & investments"
M5="Phase 5: Notes"
M6="Phase 6: News"
M7="Phase 7: Today, widgets, quick capture, search"
M8="Phase 8: Mac polish & cross-device sync"
existing_ms=$(gh api "repos/$REPO/milestones?state=all&per_page=100" -q '.[].title')
for t in "$M1" "$M2" "$M3" "$M4" "$M5" "$M6" "$M7" "$M8"; do
  grep -Fxq "$t" <<<"$existing_ms" || gh api "repos/$REPO/milestones" -f title="$t" >/dev/null
done

# --- issues -------------------------------------------------------------------
existing_titles=$(gh issue list --repo "$REPO" --state all --limit 1000 --json title -q '.[].title')

slug() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//'; }

# usage: issue "Title" "label,label" "Milestone" <<'EOF' body EOF
issue() {
  local title=$1 labels=$2 ms=$3 body url num
  body=$(cat)
  if grep -Fxq "$title" <<<"$existing_titles"; then echo "skip: $title"; return; fi
  url=$(gh issue create --repo "$REPO" --title "$title" --label "$labels" --milestone "$ms" --body "$body")
  num=${url##*/}
  gh issue edit "$num" --repo "$REPO" --body "$body

**Branch:** \`feature/$num-$(slug "$title")\`" >/dev/null
  echo "#$num $title"
}

source "$(dirname "$0")/issues.sh"
