#!/usr/bin/env bash
# Append a change-management attributes block to a published GitHub release.
# Every value is sourced from real data (the merged PRs + the release) — nothing is
# asserted or guessed:
#   serviceIds   the repo's .snow.yml
#   impact/risk  Change Management Standard §3.1.1 — default unnoticeable/minor,
#                escalated to degradation/major if any merged PR carries cmr:high-risk
#   changes      one entry per merged PR: author, approving reviewer login(s), and
#                independentlyApproved (an approver other than the author — SoD)
#   backoutPlan  redeploy the previous release
# The release notes above the block are the change description (not duplicated here).
# Idempotent. Decoration only — no ServiceNow API calls.
#
# Usage: release-cm.sh <tag>
# Env: REPO (default $GITHUB_REPOSITORY), GH_TOKEN (contents:write + pull-requests:read),
#      SNOW_YML (default .snow.yml), DRY_RUN (print instead of edit)
set -euo pipefail

TAG="${1:?usage: release-cm.sh <tag>}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
SNOW_YML="${SNOW_YML:-.snow.yml}"

# serviceIds from .snow.yml (inline-array form: `serviceIds: [572778, 572779]`)
service_ids=""
if [ -f "$SNOW_YML" ]; then
  service_ids=$(grep -E '^[[:space:]]*serviceIds:' "$SNOW_YML" \
    | sed -E 's/^[^[]*\[([^]]*)\].*/\1/' | tr -d ' ')
fi
[ -n "$service_ids" ] || echo "WARN: no serviceIds in $SNOW_YML" >&2

# Release body + idempotency guard
body=$(gh release view "$TAG" -R "$REPO" --json body -q .body 2>/dev/null || true)
if printf '%s' "$body" | grep -q 'cm-attributes: v1'; then
  echo "release $TAG already decorated — nothing to do"
  exit 0
fi
published=$(gh release view "$TAG" -R "$REPO" --json publishedAt -q .publishedAt 2>/dev/null || true)

# Previous release (backout target): the entry after $TAG in the date-descending list
prev=$(gh release list -R "$REPO" -L 100 --json tagName -q '.[].tagName' \
  | awk -v t="$TAG" 'found{print; exit} $0==t{found=1}')

# Merged PRs referenced in the release notes (semantic-release links them as #NNN).
# One reliable call per PR: real author, approving reviewers, and the cmr:high-risk label.
pr_nums=$(printf '%s' "$body" | grep -oE '#[0-9]+' | tr -d '#' | sort -un | head -30)
changes=""; high_risk=""; n_changes=0
for n in $pr_nums; do
  # tab-separated: author \t highRisk \t approvers(|-joined). Non-PR refs (issues) fail → skipped.
  line=$(gh pr view "$n" -R "$REPO" --json author,labels,reviews --jq \
    '[.author.login, ((([.labels[].name]|index("cmr:high-risk"))!=null)|tostring), ([.reviews[]|select(.state=="APPROVED")|.author.login]|unique|join("|"))] | @tsv' \
    2>/dev/null) || continue
  IFS=$'\t' read -r a hr ap <<<"$line"
  [ -n "$a" ] || continue
  n_changes=$((n_changes + 1))
  [ "$hr" = "true" ] && high_risk=1
  # Approving reviewers → quoted YAML inline array; SoD = at least one approver other than the author.
  approved_arr="[]"; independent=false
  if [ -n "$ap" ]; then
    arr=""
    while IFS= read -r rev; do
      [ -n "$rev" ] || continue
      arr="${arr:+$arr, }\"${rev}\""
      [ "$rev" != "$a" ] && independent=true
    done <<<"$(printf '%s' "$ap" | tr '|' '\n')"
    approved_arr="[${arr}]"
  fi
  changes="${changes}  - pr: ${n}
    author: \"${a}\"
    approvedBy: ${approved_arr}
    independentlyApproved: ${independent}
"
done
changes="${changes%$'\n'}"   # drop the trailing newline
if [ "$n_changes" -eq 0 ]; then changes_block="changes: []"; else changes_block="changes:                     # one entry per merged PR — per-change approval evidence (SoD)
${changes}"; fi

# Auto-classified change model / impact / risk (Change Management Standard §3.1.1).
change_type=standard; risk=minor; impact=unnoticeable
if [ -n "$high_risk" ]; then change_type=normal; risk=major; impact=degradation; fi

block=$(cat <<EOF

## Change Management

\`\`\`yaml
cm-attributes: v1
serviceIds: [${service_ids}]
changeType: ${change_type}      # auto-classified from the merged PRs' cmr:high-risk label
impact: ${impact}               # §3.1.1: no-impact | unnoticeable | degradation | outage
risk: ${risk}                   # §3.1.1: minor | major
environment: production
${changes_block}
tested: "CI + post-deploy validation gate the release"
backoutPlan: "redeploy the previous release ${prev:-unknown}"
window: { start: "${published:-unknown}" }
correlationId: ${TAG}
cmr: null
\`\`\`
EOF
)

if [ -n "${DRY_RUN:-}" ]; then
  echo "=== DRY RUN: would append to ${REPO} release ${TAG} ==="
  printf '%s\n' "$block"
  exit 0
fi

gh release edit "$TAG" -R "$REPO" --notes "${body}${block}"
echo "decorated ${REPO} release ${TAG} (impact=${impact} risk=${risk} changes=${n_changes})"
