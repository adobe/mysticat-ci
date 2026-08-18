#!/usr/bin/env bash
# Append a Change Management attributes block to a published GitHub release.
#
# Fail-closed by design. On any hard failure — a GitHub lookup that errors, a malformed
# .snow.yml, an invalid assessment value in a PR — the script logs to the run (stderr /
# ::error::) and EXITS WITHOUT MODIFYING the release description. It never writes a
# partial, invalid, or guessed record, and it never writes an error into the release
# notes. Missing NON-critical data (e.g. the previous release used as the backout target,
# or the publish time) is written as "unknown", not treated as a failure.
#
# Values (sourced from the merged PRs and the release):
#   serviceIds    the repo's .snow.yml (required; absent or unparseable => abort).
#   impact/risk   the aggregate (highest) across the release's PRs — each PR's own
#                 cm-assessment block (written at PR time by the `cmr` skill) when present,
#                 otherwise the §3.1.1 baseline (unnoticeable/minor). Unassessed PRs floor
#                 at the baseline, so assessing a PR can only raise the rating, never lower
#                 it. The cmr:high-risk label is an escalate-only floor.
#   changeType    max of the PRs' declared changeType and the severity-derived model.
#   changes       one entry per merged PR: author, approving reviewer login(s) (each
#                 reviewer's latest review, kept only if APPROVED), independentlyApproved
#                 (a non-bot reviewer other than the author approved), and the PR's own
#                 assessed impact/risk when present.
#   assessedFrom / assessedCoverage  honest provenance (how many PRs carried an assessment).
#
# Content in the repos is trusted; the script validates for syntax mistakes only. A human
# can override the result: the script never overwrites an existing block, so editing the
# Change Management block in the release notes (or the PR's cm-assessment block before the
# release is cut) is preserved.
#
# Idempotent. Decoration only — no ServiceNow API calls.
#
# Usage: release-cm.sh <tag>
# Env: REPO (default $GITHUB_REPOSITORY), GH_TOKEN (contents:write + pull-requests:read),
#      SNOW_YML (default .snow.yml), DRY_RUN (print instead of edit)
set -euo pipefail

log_err()  { echo "::error::release-cm: $*" >&2; }
log_warn() { echo "::warning::release-cm: $*" >&2; }
die()      { log_err "$*"; exit 1; }

# --- §3.1.1 severity helpers (rank <-> name; validation) ---
impact_rank() { case "$1" in no-impact) echo 0;; unnoticeable) echo 1;; degradation) echo 2;; outage) echo 3;; *) echo -1;; esac; }
risk_rank()   { case "$1" in minor) echo 0;; major) echo 1;; *) echo -1;; esac; }
ctype_rank()  { case "$1" in standard) echo 0;; normal) echo 1;; emergency) echo 2;; *) echo -1;; esac; }
impact_name() { case "$1" in 3) echo outage;; 2) echo degradation;; 0) echo no-impact;; *) echo unnoticeable;; esac; }
risk_name()   { case "$1" in 1) echo major;; *) echo minor;; esac; }
ctype_name()  { case "$1" in 2) echo emergency;; 1) echo normal;; *) echo standard;; esac; }
valid_impact() { case "$1" in no-impact|unnoticeable|degradation|outage) return 0;; *) return 1;; esac; }
valid_risk()   { case "$1" in minor|major) return 0;; *) return 1;; esac; }
valid_ctype()  { case "$1" in standard|normal|emergency) return 0;; *) return 1;; esac; }
is_bot()       { case "$1" in *"[bot]"|app/*) return 0;; *) return 1;; esac; }

TAG="${1:?usage: release-cm.sh <tag>}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
SNOW_YML="${SNOW_YML:-.snow.yml}"

# --- serviceIds from .snow.yml (required). Supports inline `[a, b]` and block-list forms.
[ -f "$SNOW_YML" ] || die "no $SNOW_YML — repo is not onboarded for change management; refusing to write an unattributed record"
service_ids=$(awk '
  found==0 && /^[[:space:]]*serviceIds:[[:space:]]*\[/ {
    l=$0; sub(/^[^[]*\[/,"",l); sub(/\].*/,"",l); gsub(/[[:space:]]/,"",l); out=l; found=1; exit
  }
  found==0 && /^[[:space:]]*serviceIds:[[:space:]]*(#.*)?$/ { inblk=1; next }
  inblk==1 {
    if ($0 ~ /^[[:space:]]*-[[:space:]]*[0-9]+/) { n=$0; gsub(/[^0-9]/,"",n); out=out (out==""?"":",") n; next }
    if ($0 ~ /^[[:space:]]*(#.*)?$/) { next }
    inblk=0
  }
  END { print out }
' "$SNOW_YML")
printf '%s' "$service_ids" | grep -qE '^[0-9]+(,[0-9]+)*$' \
  || die "$SNOW_YML has no parseable serviceIds (expected inline [id, id] or a block list of integers); got: '${service_ids}'"
ids_fmt=$(printf '%s' "$service_ids" | sed 's/,/, /g')

# --- Release body (critical) + idempotency guard (anchored: a human/tool block is kept).
body=$(gh release view "$TAG" -R "$REPO" --json body -q .body 2>/dev/null) \
  || die "cannot read release $TAG (release left unmodified)"
if printf '%s\n' "$body" | grep -qE '^[[:space:]]*cm-attributes: v1[[:space:]]*$'; then
  echo "release $TAG already has a change-management block — leaving it unchanged"
  exit 0
fi

# --- Non-critical fields: degrade to "unknown" rather than fail.
published=$(gh release view "$TAG" -R "$REPO" --json publishedAt -q .publishedAt 2>/dev/null || true)
case "$published" in ""|null) published=unknown;; esac
prev=$(gh release list -R "$REPO" -L 200 --json tagName,isDraft,isPrerelease \
  -q '[.[]|select(.isDraft==false and .isPrerelease==false)|.tagName]|.[]' 2>/dev/null \
  | awk -v t="$TAG" 'found{print; exit} $0==t{found=1}' || true)
[ -n "$prev" ] || prev=unknown

# --- Merged PRs referenced in the release notes (semantic-release links them as #NNN).
pr_nums=$(printf '%s\n' "$body" | grep -oE '#[0-9]+' | tr -d '#' | sort -un || true)
n_refs=$(printf '%s' "$pr_nums" | wc -w | tr -d ' ')
[ "${n_refs:-0}" -gt 200 ] && log_warn "release references $n_refs PR/issue refs; processing all of them"

changes=""; high_risk=""; n_changes=0; n_assessed=0
agg_impact=1; agg_risk=0; agg_ctype=0   # baseline floor: unnoticeable / minor / standard
for n in $pr_nums; do
  errf=$(mktemp)
  if ! pr_json=$(gh pr view "$n" -R "$REPO" --json author,labels,reviews,body 2>"$errf"); then
    if grep -qiE 'Could not resolve to (a |an )?(PullRequest|Issue)|no pull requests found|not found' "$errf"; then
      rm -f "$errf"; continue                       # a #NNN that is an issue, not a PR — skip
    fi
    msg=$(tr '\n' ' ' <"$errf"); rm -f "$errf"
    die "failed to look up PR #$n: ${msg} (release left unmodified)"   # transient/critical => fail closed
  fi
  rm -f "$errf"

  a=$(printf '%s' "$pr_json" | jq -r '.author.login // ""')
  [ -n "$a" ] || continue
  n_changes=$((n_changes + 1))
  [ "$(printf '%s' "$pr_json" | jq -r '(([.labels[].name]|index("cmr:high-risk"))!=null)')" = "true" ] && high_risk=1

  # Approving reviewers: each reviewer's LATEST review, kept only if its state is APPROVED.
  approvers=$(printf '%s' "$pr_json" | jq -r \
    '[.reviews[]|select(.author.login!=null)]|group_by(.author.login)|map(sort_by(.submittedAt)|last)|map(select(.state=="APPROVED"))|.[].author.login' \
    2>/dev/null || true)
  approved_arr="[]"; independent=false
  if [ -n "$approvers" ]; then
    arr=""
    while IFS= read -r rev; do
      [ -n "$rev" ] || continue
      arr="${arr:+$arr, }\"${rev}\""
      if [ "$rev" != "$a" ] && ! is_bot "$rev"; then independent=true; fi
    done <<<"$approvers"
    approved_arr="[${arr}]"
  fi

  # PR cm-assessment block (the LAST one wins). Validate any present value; a syntax
  # mistake (invalid enum) is a hard failure — abort, do not record a wrong rating.
  pr_body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
  pr_impact=""; pr_risk=""; pr_ctype=""
  if printf '%s\n' "$pr_body" | grep -qE '^[[:space:]]*cm-assessment: v1[[:space:]]*$'; then
    blk=$(printf '%s\n' "$pr_body" | awk '
      /^[[:space:]]*cm-assessment: v1[[:space:]]*$/ { cap=1; buf=$0 ORS; next }
      cap && /^[[:space:]]*```/ { last=buf; cap=0; next }
      cap { buf=buf $0 ORS }
      END { printf "%s", last }')
    pr_impact=$(printf '%s' "$blk" | sed -nE 's/^[[:space:]]*impact:[[:space:]]*([^[:space:]#]+).*/\1/p'     | head -1)
    pr_risk=$(printf   '%s' "$blk" | sed -nE 's/^[[:space:]]*risk:[[:space:]]*([^[:space:]#]+).*/\1/p'       | head -1)
    pr_ctype=$(printf  '%s' "$blk" | sed -nE 's/^[[:space:]]*changeType:[[:space:]]*([^[:space:]#]+).*/\1/p' | head -1)
    [ -z "$pr_impact" ] || valid_impact "$pr_impact" || die "PR #$n cm-assessment: invalid impact '${pr_impact}' (expected no-impact|unnoticeable|degradation|outage)"
    [ -z "$pr_risk" ]   || valid_risk   "$pr_risk"   || die "PR #$n cm-assessment: invalid risk '${pr_risk}' (expected minor|major)"
    [ -z "$pr_ctype" ]  || valid_ctype  "$pr_ctype"  || die "PR #$n cm-assessment: invalid changeType '${pr_ctype}' (expected standard|normal|emergency)"
    [ -n "${pr_impact}${pr_risk}${pr_ctype}" ] && n_assessed=$((n_assessed + 1))
  fi

  # Aggregate = max. Unassessed PRs use the §3.1.1 baseline so they never lower the rating.
  ir=$(impact_rank "${pr_impact:-unnoticeable}"); [ "$ir" -gt "$agg_impact" ] && agg_impact=$ir
  rr=$(risk_rank "${pr_risk:-minor}");            [ "$rr" -gt "$agg_risk" ]   && agg_risk=$rr
  if [ -n "$pr_ctype" ]; then cr=$(ctype_rank "$pr_ctype"); [ "$cr" -gt "$agg_ctype" ] && agg_ctype=$cr; fi

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
changes="${changes%$'\n'}"
if [ "$n_changes" -eq 0 ]; then changes_block="changes: []"; else changes_block="changes:                     # one entry per merged PR
${changes}"; fi

# --- Resolve impact/risk, apply the escalate-only label floor, derive the change model.
impact=$(impact_name "$agg_impact")
risk=$(risk_name "$agg_risk")
if [ -n "$high_risk" ]; then
  [ "$(impact_rank "$impact")" -lt 2 ] && { impact=degradation; agg_impact=2; }
  [ "$(risk_rank "$risk")" -lt 1 ]     && { risk=major;         agg_risk=1; }
fi
sev_ct=0; { [ "$risk" = major ] || [ "$(impact_rank "$impact")" -ge 2 ]; } && sev_ct=1
[ "$sev_ct" -gt "$agg_ctype" ] && agg_ctype=$sev_ct
change_type=$(ctype_name "$agg_ctype")

if [ "$n_assessed" -gt 0 ]; then assessed_from=pr-cm-assessment; else assessed_from=heuristic; fi
coverage="${n_assessed}/${n_changes} PRs assessed"

block=$(cat <<EOF

## Change Management

\`\`\`yaml
cm-attributes: v1
serviceIds: [${ids_fmt}]
changeType: ${change_type}      # standard | normal | emergency
impact: ${impact}               # §3.1.1: no-impact | unnoticeable | degradation | outage
risk: ${risk}                   # §3.1.1: minor | major
assessedFrom: ${assessed_from}  # pr-cm-assessment | heuristic
assessedCoverage: "${coverage}"
environment: production
${changes_block}
tested: "see this release's CI checks and post-deploy validation"
backoutPlan: "redeploy the previous release ${prev}"
window: { start: "${published}" }
correlationId: "${TAG}"
cmr: null
\`\`\`
EOF
)

if [ -n "${DRY_RUN:-}" ]; then
  echo "=== DRY RUN: would append to ${REPO} release ${TAG} ==="
  printf '%s\n' "$block"
  exit 0
fi

gh release edit "$TAG" -R "$REPO" --notes "${body}${block}" \
  || die "failed to update release $TAG (release left unmodified)"
echo "decorated ${REPO} release ${TAG} (impact=${impact} risk=${risk} changeType=${change_type} assessed=${coverage})"
