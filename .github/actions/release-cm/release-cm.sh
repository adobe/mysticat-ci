#!/usr/bin/env bash
# Append a Change Management attributes block to a published GitHub release.
#
# Two failure philosophies, on purpose:
#   * CONFIG / INFRA errors — cannot read the release, no pull-requests:read scope, a
#     missing or malformed .snow.yml, a transient/critical `gh` error — are FAIL-CLOSED:
#     log ::error:: and EXIT WITHOUT MODIFYING the release. Never a partial/guessed record,
#     never an error written into the release notes.
#   * ASSESSMENT-CONTENT problems — a PR whose cm-assessment block is unparseable, has an
#     invalid value, is missing impact/risk/changeType, uses a multi-line backout we cannot
#     capture, or a cmr:high-risk label that conflicts with the PR's own low self-assessment
#     — do NOT abort. The release is still recorded, with `assessmentStatus: needs-review`
#     (and the offending field shown as `unknown`) so a human knows to look, rather than
#     silently defaulting to low or blocking the whole release over one PR.
#
# assessmentStatus (the coverage signal a human scans for):
#   assessed      every merged PR carried a valid cm-assessment  ("assessed low-risk" = this + low values)
#   partial       some PRs assessed, the rest floored to the §3.1.1 baseline
#   unassessed    no PR carried an assessment (heuristic baseline) — worth a look
#   needs-review  a PR's assessment was unparseable/invalid/incomplete, a label/assessment
#                 conflict, or the PR carried MULTIPLE cm-assessment blocks that disagree
#
# Values:
#   serviceIds    the repo's .snow.yml (required; inline `[a, b]` or block list of integers).
#   impact/risk   the aggregate (highest) across the PRs. An UNASSESSED or UNKNOWN field
#                 floors at the §3.1.1 baseline (unnoticeable/minor); an ASSESSED PR uses its
#                 own value (which may be no-impact); the release takes the max. The
#                 cmr:high-risk label is an optional escalate-only floor (block = primary signal).
#   changeType    standard|normal from the change's nature (severity); emergency is set only
#                 from a release-level signal (a hotfix-style tag or RELEASE_CM_EMERGENCY), never
#                 aggregated up from a PR that merely fixed an incident.
#   changes[]     per merged PR: author, approving reviewer login(s) (each reviewer's latest
#                 review, kept only if APPROVED), independentlyApproved (a reviewer other than
#                 the author AND not the CI identity approved — human or AI agent; an
#                 approval-independence signal, not a full SoD attestation), the PR's own
#                 impact/risk (or `unknown` per field when invalid), and its backout if given.
#
# Content in the repos is trusted; the script validates for syntax mistakes only. A human
# can override the result: the script never overwrites an existing block, so editing the
# Change Management block in the release notes (or the PR's cm-assessment block before the
# release is cut) is preserved. To override a PR's assessment, EDIT its block in place —
# appending a second, disagreeing block does not silently win; it resolves to needs-review.
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
yamlstr()  { jq -Rn --arg s "$1" '$s'; }   # encode arbitrary text as a valid (quoted) YAML/JSON scalar
errf=""; trap 'rm -f "${errf:-}"' EXIT

# Reviewer logins that are the CI/publishing identity, not an independent reviewer — an
# auto-approve step running as one of these is self-approval by proxy, not segregation.
CI_IDENTITIES="github-actions[bot]"

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
  # independentlyApproved = a reviewer other than the author AND not the CI/publishing
  # identity approved — human OR AI agent (an approval-independence signal, not a full SoD
  # attestation; whether an agent approval satisfies the CM Standard's SoD is a CM Process
  # Owner question). Only the CI identity is excluded, so a real reviewing agent still counts.
  approvers=$(printf '%s' "$pr_json" | jq -r \
    '[.reviews[]|select(.author.login!=null)]|group_by(.author.login)|map(sort_by(.submittedAt)|last)|map(select(.state=="APPROVED"))|.[].author.login' \
    2>/dev/null || true)
  approved_arr="[]"; independent=false
  if [ -n "$approvers" ]; then
    arr=""
    while IFS= read -r rev; do
      [ -n "$rev" ] || continue
      arr="${arr:+$arr, }$(yamlstr "$rev")"
      [ "$rev" != "$a" ] && ! grep -qxF -- "$rev" <<<"$CI_IDENTITIES" && independent=true
    done <<<"$approvers"
    approved_arr="[${arr}]"
  fi

  # PR cm-assessment block. A single block (or several that AGREE on the gating fields) is used;
  # per-field, a present-but-invalid value is shown as `unknown` and flags needs-review, and a
  # structurally broken block flags the PR. MULTIPLE blocks that DISAGREE resolve to unknown /
  # needs-review — a human must reduce them to one authoritative block (that is how override works).
  pr_body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
  pr_impact=""; pr_risk=""; pr_ctype=""; pr_backout=""
  impact_bad=""; risk_bad=""; flag=""; unparsed=""; conflict=""; conf_im=""; conf_rk=""
  if printf '%s\n' "$pr_body" | grep -qE '^[[:space:]]*cm-assessment: v1[[:space:]]*$'; then
    # Signature (impact|risk|changeType) of every CLOSED block; >1 distinct == conflicting blocks.
    sigs=$(printf '%s\n' "$pr_body" | awk '
      /^[[:space:]]*cm-assessment: v1[[:space:]]*$/ { cap=1; im=""; rk=""; ct=""; next }
      cap && /^[[:space:]]*```/ { printf "%s|%s|%s\n", tolower(im), tolower(rk), tolower(ct); cap=0; next }
      cap && /^[[:space:]]*impact:/     { if (im=="") { s=$0; sub(/^[[:space:]]*impact:[[:space:]]*/,"",s);     sub(/[[:space:]#].*$/,"",s); im=s } }
      cap && /^[[:space:]]*risk:/       { if (rk=="") { s=$0; sub(/^[[:space:]]*risk:[[:space:]]*/,"",s);       sub(/[[:space:]#].*$/,"",s); rk=s } }
      cap && /^[[:space:]]*changeType:/ { if (ct=="") { s=$0; sub(/^[[:space:]]*changeType:[[:space:]]*/,"",s); sub(/[[:space:]#].*$/,"",s); ct=s } }')
    ndistinct=$({ printf '%s\n' "$sigs" | grep . || true; } | sort -u | wc -l | tr -d ' ')
    nclosed=$({ printf '%s\n' "$sigs" | grep -c . || true; }); nclosed=${nclosed:-0}
    nmarkers=$({ printf '%s\n' "$pr_body" | grep -cE '^[[:space:]]*cm-assessment: v1[[:space:]]*$' || true; }); nmarkers=${nmarkers:-0}
    if [ "$nmarkers" -gt "$nclosed" ]; then
      # a marker without a closing fence (possibly hiding behind a well-formed sibling block)
      unparsed=1; flag=1; blk=""
      log_warn "PR #$n: a cm-assessment block is not closed by a fence — needs-review"
    elif [ "${ndistinct:-0}" -gt 1 ]; then
      conflict=1; unparsed=1; flag=1; blk=""
      log_warn "PR #$n: multiple conflicting cm-assessment blocks — needs-review (leave exactly one authoritative block)"
      # Contribute the HIGHEST severity any block claimed so a conflict never UNDER-rates the
      # release (the per-PR fields still show `unknown`; needs-review makes a human resolve it).
      conf_im=$(printf '%s\n' "$sigs" | awk -F'|' 'function r(x){return x=="outage"?4:x=="degradation"?3:x=="unnoticeable"?2:x=="no-impact"?1:0}{v=r($1);if(v>b){b=v;o=$1}}END{print o}')
      conf_rk=$(printf '%s\n' "$sigs" | awk -F'|' 'function r(x){return x=="major"?2:x=="minor"?1:0}{v=r($2);if(v>b){b=v;o=$2}}END{print o}')
      valid_impact "$conf_im" || conf_im=""
      valid_risk   "$conf_rk" || conf_rk=""
    else
    blk=$(printf '%s\n' "$pr_body" | awk '
      /^[[:space:]]*cm-assessment: v1[[:space:]]*$/ { cap=1; buf=$0 ORS; next }
      cap && /^[[:space:]]*```/ { last=buf; cap=0; next }
      cap { buf=buf $0 ORS }
      END { printf "%s", last }')
    if [ -z "$blk" ]; then
      unparsed=1; flag=1; log_warn "PR #$n: cm-assessment marker with no closed fenced block — needs-review"
    else
      pr_impact=$(lc "$(printf '%s' "$blk" | sed -nE 's/^[[:space:]]*impact:[[:space:]]*([^[:space:]#]+).*/\1/p'     | head -1)")
      pr_risk=$(lc "$(printf   '%s' "$blk" | sed -nE 's/^[[:space:]]*risk:[[:space:]]*([^[:space:]#]+).*/\1/p'       | head -1)")
      pr_ctype=$(lc "$(printf  '%s' "$blk" | sed -nE 's/^[[:space:]]*changeType:[[:space:]]*([^[:space:]#]+).*/\1/p' | head -1)")
      pr_backout=$(printf '%s' "$blk" | sed -nE 's/^[[:space:]]*backout:[[:space:]]*(.+)$/\1/p' | head -1)
      case "$pr_backout" in '"'*'"') pr_backout=${pr_backout#\"}; pr_backout=${pr_backout%\"};; esac  # strip only matched surrounding quotes
      # A multi-line block scalar header (exactly |, >, optionally an indent digit / chomp,
      # and nothing else on the line) cannot be captured single-line — flag it. Free text
      # that merely starts with | or > (e.g. "> rollback via flag") is kept.
      case "$pr_backout" in
        '|'|'>'|'|'[-+]|'>'[-+]|'|'[0-9]|'>'[0-9]|'|'[0-9][-+]|'>'[0-9][-+]|'|'[-+][0-9]|'>'[-+][0-9])
          log_warn "PR #$n: multi-line backout not captured (use a single-line backout) — needs-review"; pr_backout=""; flag=1;;
      esac
      if [ -n "$pr_impact" ] && ! valid_impact "$pr_impact"; then impact_bad=1; flag=1; log_warn "PR #$n: invalid impact '${pr_impact}' — needs-review"; pr_impact=""; fi
      if [ -n "$pr_risk" ]   && ! valid_risk   "$pr_risk";   then risk_bad=1;   flag=1; log_warn "PR #$n: invalid risk '${pr_risk}' — needs-review";   pr_risk=""; fi
      if [ -n "$pr_ctype" ]  && ! valid_ctype  "$pr_ctype";  then flag=1;               log_warn "PR #$n: invalid changeType '${pr_ctype}' — needs-review"; pr_ctype=""; fi
      if [ -z "${pr_impact}${pr_risk}${pr_ctype}" ] && [ -z "${impact_bad}${risk_bad}${flag}" ]; then
        unparsed=1; flag=1; log_warn "PR #$n: cm-assessment has none of impact/risk/changeType — needs-review"
      fi
      [ -n "${pr_impact}${pr_risk}${pr_ctype}" ] && n_assessed=$((n_assessed + 1))
    fi
    fi
    [ -n "$flag" ] && { n_unknown=$((n_unknown + 1)); needs_review=1; }
  fi

  # Aggregate = max. Unassessed/unknown fields use the baseline so they never lower the rating;
  # a conflicting PR contributes the highest severity any of its blocks claimed (conf_im/conf_rk)
  # so it is never under-rated while it waits for a human.
  ir=$(impact_rank "${pr_impact:-${conf_im:-unnoticeable}}"); [ "$ir" -gt "$agg_impact" ] && agg_impact=$ir
  rr=$(risk_rank "${pr_risk:-${conf_rk:-minor}}");            [ "$rr" -gt "$agg_risk" ]   && agg_risk=$rr
  # A PR is classified by its own nature (standard|normal); emergency is a deploy attribute
  # (context), so a PR that merely fixed an incident is IGNORED here and the change's own
  # severity governs — it does not make the bundling release emergency (or even normal).
  [ "$pr_ctype" = emergency ] && pr_ctype=""
  if [ -n "$pr_ctype" ]; then cr=$(ctype_rank "$pr_ctype"); [ "$cr" -gt "$agg_ctype" ] && agg_ctype=$cr; fi

  # Per-PR display: each field shows its value if valid, `unknown` if present-but-invalid or
  # the block was structurally unusable, and is omitted if the PR simply carried no assessment.
  di=""; if [ -n "$pr_impact" ]; then di=$pr_impact; elif [ -n "$impact_bad" ] || [ -n "$unparsed" ]; then di=unknown; fi
  dr=""; if [ -n "$pr_risk" ];   then dr=$pr_risk;   elif [ -n "$risk_bad" ]   || [ -n "$unparsed" ]; then dr=unknown; fi
  extra=""
  [ -n "$di" ] && extra="${extra}
    impact: ${di}"
  [ -n "$dr" ] && extra="${extra}
    risk: ${dr}"
  if [ -n "$conflict" ]; then extra="${extra}
    note: \"multiple conflicting cm-assessment blocks — needs review\""
  elif [ -n "$flag" ]; then extra="${extra}
    note: \"cm-assessment unparseable/invalid — needs review\""
  fi
  [ -n "$pr_backout" ] && extra="${extra}
    backout: $(yamlstr "$pr_backout")"
  changes="${changes}  - pr: ${n}
    author: $(yamlstr "$a")
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
  # cmr:high-risk but a PR's own assessment claimed low on EITHER dimension => conflict.
  [ "$n_assessed" -gt 0 ] && { [ "$pre_impact" -lt 2 ] || [ "$pre_risk" -lt 1 ]; } && needs_review=1
fi
impact=$(impact_name "$agg_impact")
risk=$(risk_name "$agg_risk")
# Gate on RISK (reversibility/recoverability), not blast-radius alone: a reversible/recoverable
# `degradation` stays standard; only `major` risk (or an `outage` impact, which is by definition
# unrecoverable/product-wide) escalates to normal.
sev_ct=0; { [ "$agg_risk" -ge 1 ] || [ "$agg_impact" -ge 3 ]; } && sev_ct=1
[ "$sev_ct" -gt "$agg_ctype" ] && agg_ctype=$sev_ct
change_type=$(ctype_name "$agg_ctype")   # standard | normal from the change's nature
# Emergency is dictated by the DEPLOY, not by a bundled change: an out-of-band urgent hotfix
# deploy. Detect it from the release itself (a hotfix-style tag, or an explicit operator flag);
# never aggregate it up from a PR.
case "$TAG" in *[Hh]otfix*|*[Ee]mergency*) change_type=emergency;; esac
[ -n "${RELEASE_CM_EMERGENCY:-}" ] && change_type=emergency

# --- assessmentStatus: the coverage/confidence signal a human scans for.
if   [ -n "$needs_review" ];              then status=needs-review
elif [ "$n_changes" -eq 0 ];              then status=unassessed
elif [ "$n_assessed" -eq 0 ];             then status=unassessed
elif [ "$n_assessed" -lt "$n_changes" ];  then status=partial
else                                            status=assessed
fi
coverage="${n_assessed}/${n_changes} PRs assessed"
[ "$n_unknown" -gt 0 ] && coverage="${coverage} (${n_unknown} flagged needs-review)"

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
backoutPlan: $(yamlstr "$backout")
window: { start: $(yamlstr "$published") }
correlationId: $(yamlstr "$TAG")
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
