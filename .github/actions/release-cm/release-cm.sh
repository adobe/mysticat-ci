#!/usr/bin/env bash
# Append a Change Management attributes block to a published GitHub release.
#
# Two failure philosophies, on purpose:
#   * CONFIG / INFRA errors — cannot read the release, no pull-requests:read scope, a
#     missing or malformed .snow.yml, a transient/critical `gh` error — are FAIL-CLOSED:
#     log ::error:: and EXIT WITHOUT MODIFYING the release. Never a partial/guessed record,
#     never an error written into the release notes.
#   * ASSESSMENT-CONTENT problems — a PR whose cm-assessment block is unparseable, has an
#     invalid value, or is missing impact/risk/changeType, or a cmr:high-risk label that
#     conflicts with the PR's own low self-assessment — do NOT abort. The release is still
#     recorded, with `assessmentStatus: needs-review` so a human knows to look, rather than
#     silently defaulting to low or blocking the whole release over one PR.
#
# assessmentStatus (the coverage signal a human scans for):
#   assessed      every merged PR carried a valid cm-assessment  ("assessed low-risk" = this + low values)
#   partial       some PRs assessed, the rest floored to the §3.1.1 baseline
#   unassessed    no PR carried an assessment (heuristic baseline) — worth a look
#   needs-review  a PR's assessment was unparseable/invalid, or a label/assessment conflict
#
# Values:
#   serviceIds    the repo's .snow.yml (required; inline `[a, b]` or block list of integers).
#   impact/risk   the aggregate (highest) across the PRs — each PR's cm-assessment block
#                 (written at PR time by the `cmr` skill) when present, else the §3.1.1
#                 baseline (unnoticeable/minor). Unassessed/unknown PRs floor at the
#                 baseline, so assessing a PR can only raise the rating. The cmr:high-risk
#                 label is an optional escalate-only floor (the block is the primary signal).
#   changeType    max of the PRs' declared changeType and the severity-derived model.
#   changes[]     per merged PR: author, approving reviewer login(s) (each reviewer's latest
#                 review, kept only if APPROVED), independentlyApproved (a reviewer other
#                 than the author approved — human OR AI agent, an ai-native org), the PR's
#                 own impact/risk (or unknown when unparseable), and its backout if provided.
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
lc()       { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
errf=""; trap 'rm -f "${errf:-}"' EXIT

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

TAG="${1:?usage: release-cm.sh <tag>}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
SNOW_YML="${SNOW_YML:-.snow.yml}"

# --- serviceIds from .snow.yml (required; CONFIG error => fail closed). Inline + block forms.
[ -f "$SNOW_YML" ] || die "no $SNOW_YML — repo is not onboarded for change management; refusing to write an unattributed record"
service_ids=$(awk '
  found==0 && /^[[:space:]]*serviceIds:[[:space:]]*\[/ {
    l=$0; sub(/^[^[]*\[/,"",l); sub(/\].*/,"",l); gsub(/[[:space:]]/,"",l); out=l; found=1; exit
  }
  found==0 && /^[[:space:]]*serviceIds:[[:space:]]*(#.*)?$/ { inblk=1; next }
  inblk==1 {
    if ($0 ~ /^[[:space:]]*-[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/) {
      n=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",n); sub(/[^0-9].*$/,"",n); out=out (out==""?"":",") n; next
    }
    if ($0 ~ /^[[:space:]]*-/)          { bad=1; next }   # a list item that is not a bare integer => malformed
    if ($0 ~ /^[[:space:]]*(#.*)?$/)    { next }          # blank or comment inside the list is fine
    inblk=0                                                # dedent / next key => list ended
  }
  END { if (bad) print "!MALFORMED"; else print out }
' "$SNOW_YML")
[ "$service_ids" != "!MALFORMED" ] \
  || die "$SNOW_YML serviceIds list has a non-integer entry (fix the .snow.yml; release left unmodified)"
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
# Keep $TAG in the candidate list (even if it is a prerelease) so the anchor is found;
# only prod (non-draft, non-prerelease) releases are eligible as the backout target.
prev=$(gh release list -R "$REPO" -L 200 --json tagName,isDraft,isPrerelease 2>/dev/null \
  | jq -r --arg t "$TAG" '[.[]|select((.isDraft==false and .isPrerelease==false) or .tagName==$t)|.tagName]|.[]' 2>/dev/null \
  | awk -v t="$TAG" 'found{print; exit} $0==t{found=1}' || true)
[ -n "$prev" ] || prev=unknown

# --- Verify the token can actually see pull requests, so a genuine issue-ref (skipped
# below) is never confused with a PR made invisible by a missing scope — which would
# otherwise skip every PR and record a green, evidence-free release (fail open).
gh pr list -R "$REPO" -L 1 >/dev/null 2>&1 \
  || die "cannot list pull requests in $REPO — check the token's pull-requests:read scope and repo access (release left unmodified)"

# --- Merged PRs referenced in the release notes (semantic-release links them as #NNN).
pr_nums=$(printf '%s\n' "$body" | grep -oE '#[0-9]+' | tr -d '#' | sort -un || true)
n_refs=$(printf '%s' "$pr_nums" | wc -w | tr -d ' ')
[ "${n_refs:-0}" -gt 200 ] && log_warn "release references $n_refs PR/issue refs; processing all of them"

changes=""; high_risk=""; n_changes=0; n_assessed=0; n_unknown=0; needs_review=""
agg_impact=-1; agg_risk=-1; agg_ctype=0   # -1 = no PR seen yet; per-PR baseline applied below
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
  # independentlyApproved = a reviewer other than the author approved — human OR AI agent
  # (an ai-native org treats an agent's independent review as valid segregation of duties).
  approvers=$(printf '%s' "$pr_json" | jq -r \
    '[.reviews[]|select(.author.login!=null)]|group_by(.author.login)|map(sort_by(.submittedAt)|last)|map(select(.state=="APPROVED"))|.[].author.login' \
    2>/dev/null || true)
  approved_arr="[]"; independent=false
  if [ -n "$approvers" ]; then
    arr=""
    while IFS= read -r rev; do
      [ -n "$rev" ] || continue
      arr="${arr:+$arr, }\"${rev}\""
      [ "$rev" != "$a" ] && independent=true
    done <<<"$approvers"
    approved_arr="[${arr}]"
  fi

  # PR cm-assessment block (the LAST one wins). Assessment-content problems mark the PR
  # `unknown` and set needs-review — they do NOT abort or silently default to low.
  pr_body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
  pr_impact=""; pr_risk=""; pr_ctype=""; pr_backout=""; pr_unknown=""
  if printf '%s\n' "$pr_body" | grep -qE '^[[:space:]]*cm-assessment: v1[[:space:]]*$'; then
    blk=$(printf '%s\n' "$pr_body" | awk '
      /^[[:space:]]*cm-assessment: v1[[:space:]]*$/ { cap=1; buf=$0 ORS; next }
      cap && /^[[:space:]]*```/ { last=buf; cap=0; next }
      cap { buf=buf $0 ORS }
      END { printf "%s", last }')
    if [ -z "$blk" ]; then
      pr_unknown=1; log_warn "PR #$n: cm-assessment marker with no closed fenced block — marked needs-review"
    else
      pr_impact=$(lc "$(printf '%s' "$blk" | sed -nE 's/^[[:space:]]*impact:[[:space:]]*([^[:space:]#]+).*/\1/p'     | head -1)")
      pr_risk=$(lc "$(printf   '%s' "$blk" | sed -nE 's/^[[:space:]]*risk:[[:space:]]*([^[:space:]#]+).*/\1/p'       | head -1)")
      pr_ctype=$(lc "$(printf  '%s' "$blk" | sed -nE 's/^[[:space:]]*changeType:[[:space:]]*([^[:space:]#]+).*/\1/p' | head -1)")
      pr_backout=$(printf '%s' "$blk" | sed -nE 's/^[[:space:]]*backout:[[:space:]]*(.+)$/\1/p' | head -1)
      pr_backout=${pr_backout%\"}; pr_backout=${pr_backout#\"}
      if [ -n "$pr_impact" ] && ! valid_impact "$pr_impact"; then pr_unknown=1; log_warn "PR #$n: invalid impact '${pr_impact}' — marked needs-review"; pr_impact=""; fi
      if [ -n "$pr_risk" ]   && ! valid_risk   "$pr_risk";   then pr_unknown=1; log_warn "PR #$n: invalid risk '${pr_risk}' — marked needs-review";   pr_risk=""; fi
      if [ -n "$pr_ctype" ]  && ! valid_ctype  "$pr_ctype";  then pr_unknown=1; log_warn "PR #$n: invalid changeType '${pr_ctype}' — marked needs-review"; pr_ctype=""; fi
      if [ -z "${pr_impact}${pr_risk}${pr_ctype}" ] && [ -z "$pr_unknown" ]; then
        pr_unknown=1; log_warn "PR #$n: cm-assessment has none of impact/risk/changeType — marked needs-review"
      fi
      [ -z "$pr_unknown" ] && [ -n "${pr_impact}${pr_risk}${pr_ctype}" ] && n_assessed=$((n_assessed + 1))
    fi
    if [ -n "$pr_unknown" ]; then n_unknown=$((n_unknown + 1)); needs_review=1; fi
  fi

  # Aggregate = max. Unassessed/unknown PRs use the baseline so they never lower the rating.
  ir=$(impact_rank "${pr_impact:-unnoticeable}"); [ "$ir" -gt "$agg_impact" ] && agg_impact=$ir
  rr=$(risk_rank "${pr_risk:-minor}");            [ "$rr" -gt "$agg_risk" ]   && agg_risk=$rr
  if [ -n "$pr_ctype" ]; then cr=$(ctype_rank "$pr_ctype"); [ "$cr" -gt "$agg_ctype" ] && agg_ctype=$cr; fi

  extra=""
  if [ -n "$pr_unknown" ]; then
    extra="${extra}
    impact: unknown
    risk: unknown
    note: \"cm-assessment present but unparseable/invalid — needs review\""
  else
    [ -n "$pr_impact" ] && extra="${extra}
    impact: ${pr_impact}"
    [ -n "$pr_risk" ] && extra="${extra}
    risk: ${pr_risk}"
  fi
  [ -n "$pr_backout" ] && extra="${extra}
    backout: \"${pr_backout}\""
  changes="${changes}  - pr: ${n}
    author: \"${a}\"
    approvedBy: ${approved_arr}
    independentlyApproved: ${independent}${extra}
"
done
changes="${changes%$'\n'}"
if [ "$n_changes" -eq 0 ]; then changes_block="changes: []"; else changes_block="changes:                     # one entry per merged PR
${changes}"; fi
[ "$n_changes" -eq 0 ] && [ "${n_refs:-0}" -gt 0 ] && log_warn "referenced ${n_refs} #number(s) but none were pull requests — recorded as a no-PR release"

# No PR seen at all: fall back to the §3.1.1 baseline (unnoticeable / minor).
[ "$agg_impact" -lt 0 ] && agg_impact=1
[ "$agg_risk" -lt 0 ]   && agg_risk=0
pre_impact=$agg_impact; pre_risk=$agg_risk

# --- Escalate-only label floor (optional signal), then the controversy check.
if [ -n "$high_risk" ]; then
  [ "$agg_impact" -lt 2 ] && agg_impact=2
  [ "$agg_risk" -lt 1 ]   && agg_risk=1
  # cmr:high-risk label but the PRs' own assessments said low => conflicting signal.
  [ "$n_assessed" -gt 0 ] && [ "$pre_impact" -lt 2 ] && [ "$pre_risk" -lt 1 ] && needs_review=1
fi
impact=$(impact_name "$agg_impact")
risk=$(risk_name "$agg_risk")
sev_ct=0; { [ "$agg_risk" -ge 1 ] || [ "$agg_impact" -ge 2 ]; } && sev_ct=1
[ "$sev_ct" -gt "$agg_ctype" ] && agg_ctype=$sev_ct
change_type=$(ctype_name "$agg_ctype")

# --- assessmentStatus: the coverage/confidence signal a human scans for.
if   [ -n "$needs_review" ];              then status=needs-review
elif [ "$n_changes" -eq 0 ];              then status=unassessed
elif [ "$n_assessed" -eq 0 ];             then status=unassessed
elif [ "$n_assessed" -lt "$n_changes" ];  then status=partial
else                                            status=assessed
fi
coverage="${n_assessed}/${n_changes} PRs assessed"
[ "$n_unknown" -gt 0 ] && coverage="${coverage}; ${n_unknown} need review"

if [ "$prev" = unknown ]; then
  backout="no previous release resolved (first release, or beyond the lookup window) — document a specific rollback"
else
  backout="redeploy the previous release ${prev}"
fi

block=$(cat <<EOF

## Change Management

\`\`\`yaml
cm-attributes: v1
serviceIds: [${ids_fmt}]
changeType: ${change_type}      # standard | normal | emergency
impact: ${impact}               # §3.1.1: no-impact | unnoticeable | degradation | outage
risk: ${risk}                   # §3.1.1: minor | major
assessmentStatus: ${status}     # assessed | partial | unassessed | needs-review (a human should check needs-review)
assessedCoverage: "${coverage}"
environment: production
${changes_block}
tested: "see this release's CI checks and post-deploy validation"
backoutPlan: "${backout}"
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
echo "decorated ${REPO} release ${TAG} (impact=${impact} risk=${risk} changeType=${change_type} status=${status} coverage='${coverage}')"
