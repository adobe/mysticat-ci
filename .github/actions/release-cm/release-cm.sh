#!/usr/bin/env bash
# Append a change-management attributes block to a published GitHub release.
# Every value is sourced from real data (the merged PRs + the release) — nothing is
# asserted or guessed:
#   serviceIds   the repo's .snow.yml
#   impact/risk  the aggregate (highest) of the merged PRs' cm-assessment blocks
#                (written at PR time by the `cmr` skill); falls back to §3.1.1 defaults
#                (unnoticeable/minor). The cmr:high-risk label is a floor (escalate-only).
#   changes      one entry per merged PR: author, approving reviewer login(s),
#                independentlyApproved (an approver other than the author — SoD), and
#                the PR's own assessed impact/risk when present
#   backoutPlan  redeploy the previous release
# The release notes above the block are the change description (not duplicated here).
# Idempotent. Decoration only — no ServiceNow API calls.
#
# Usage: release-cm.sh <tag>
# Env: REPO (default $GITHUB_REPOSITORY), GH_TOKEN (contents:write + pull-requests:read),
#      SNOW_YML (default .snow.yml), DRY_RUN (print instead of edit)
set -euo pipefail

# --- §3.1.1 severity ranking helpers (for aggregating assessments across PRs) ---
impact_rank() { case "$1" in no-impact) echo 0;; unnoticeable) echo 1;; degradation) echo 2;; outage) echo 3;; *) echo -1;; esac; }
risk_rank()   { case "$1" in minor) echo 0;; major) echo 1;; *) echo -1;; esac; }
impact_name() { case "$1" in 3) echo outage;; 2) echo degradation;; 1) echo unnoticeable;; *) echo no-impact;; esac; }
risk_name()   { case "$1" in 1) echo major;; *) echo minor;; esac; }

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
agg_impact=-1; agg_risk=-1; any_assessment=""; any_emergency=""
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
  # PR cm-assessment block (written at PR time by the `cmr` skill), if present.
  pr_body=$(gh pr view "$n" -R "$REPO" --json body -q .body 2>/dev/null || true)
  pr_impact=""; pr_risk=""
  if printf '%s' "$pr_body" | grep -q 'cm-assessment: v1'; then
    blk=$(printf '%s' "$pr_body" | awk '/cm-assessment: v1/{f=1} f && /^[[:space:]]*```/{exit} f{print}')
    pr_impact=$(printf '%s' "$blk" | sed -nE 's/^[[:space:]]*impact:[[:space:]]*([a-z-]+).*/\1/p'      | head -1)
    pr_risk=$(printf   '%s' "$blk" | sed -nE 's/^[[:space:]]*risk:[[:space:]]*([a-z]+).*/\1/p'         | head -1)
    pr_ctype=$(printf  '%s' "$blk" | sed -nE 's/^[[:space:]]*changeType:[[:space:]]*([a-z]+).*/\1/p'   | head -1)
    [ -n "${pr_impact}${pr_risk}${pr_ctype:-}" ] && any_assessment=1
    [ "${pr_ctype:-}" = "emergency" ] && any_emergency=1
    ir=$(impact_rank "$pr_impact"); if [ "$ir" -gt "$agg_impact" ]; then agg_impact=$ir; fi
    rr=$(risk_rank "$pr_risk");     if [ "$rr" -gt "$agg_risk" ]; then agg_risk=$rr; fi
  fi
  # Per-PR assessed impact/risk (only when the PR carried them).
  assessed=""
  [ -n "$pr_impact" ] && assessed="${assessed}
    impact: ${pr_impact}"
  [ -n "$pr_risk" ] && assessed="${assessed}
    risk: ${pr_risk}"
  changes="${changes}  - pr: ${n}
    author: \"${a}\"
    approvedBy: ${approved_arr}
    independentlyApproved: ${independent}${assessed}
"
done
changes="${changes%$'\n'}"   # drop the trailing newline
if [ "$n_changes" -eq 0 ]; then changes_block="changes: []"; else changes_block="changes:                     # one entry per merged PR — per-change approval evidence (SoD)
${changes}"; fi

# Aggregate impact/risk from the PRs' cm-assessment blocks; fall back to §3.1.1 defaults.
change_type=standard; risk=minor; impact=unnoticeable; assessed_from=heuristic
if [ -n "$any_assessment" ]; then
  assessed_from=pr-cm-assessment
  [ "$agg_impact" -ge 0 ] && impact=$(impact_name "$agg_impact")
  [ "$agg_risk"   -ge 0 ] && risk=$(risk_name "$agg_risk")
fi
# cmr:high-risk label is a floor — it can only escalate the rating, never lower it.
if [ -n "$high_risk" ]; then
  [ "$(impact_rank "$impact")" -lt 2 ] && impact=degradation
  [ "$(risk_rank "$risk")"     -lt 1 ] && risk=major
fi
# Change model follows the resulting severity (emergency only if a PR declared it).
if [ -n "$any_emergency" ]; then change_type=emergency
elif [ "$risk" = "major" ] || [ "$(impact_rank "$impact")" -ge 2 ]; then change_type=normal
else change_type=standard; fi

block=$(cat <<EOF

## Change Management

\`\`\`yaml
cm-attributes: v1
serviceIds: [${service_ids}]
changeType: ${change_type}      # standard | normal | emergency
impact: ${impact}               # §3.1.1: no-impact | unnoticeable | degradation | outage
risk: ${risk}                   # §3.1.1: minor | major
assessedFrom: ${assessed_from}  # pr-cm-assessment (merged PRs' cmr skill) or heuristic
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
echo "decorated ${REPO} release ${TAG} (impact=${impact} risk=${risk} changeType=${change_type} from=${assessed_from} changes=${n_changes})"
