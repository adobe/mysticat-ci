#!/usr/bin/env bash
# Idempotently write a cm-assessment block into a PULL REQUEST's description — used by the
# agent-driven audit backfill (`cmr` skill) to record an inferred assessment on a PR that
# was merged without one. release-cm.sh then aggregates it into the release.
#
# Usage: cm-assess-pr.sh <pr-number> [fields-file]   (fields on stdin if the file is omitted)
#   <fields-file> holds the assessment as flat `key: scalar` lines, e.g.:
#     changeType: normal
#     impact: degradation
#     risk: major
#     rationale: "adds a DB migration; not auto-reversible"
#   Only changeType/impact/risk/rationale are emitted; any other keys (pr, title, scope, …) are
#   dropped. Each key must appear at most once — a duplicate is rejected as ambiguous/tampered.
#
# Behaviour: appends a fenced `cm-assessment: v1` block under a `## Change Management`
# heading, preserving the rest of the PR body. Skips if the PR already has a block (a human
# or earlier run wrote one) unless FORCE=1. Validates impact + risk against the §3.1.1 enums.
# Also records `changeApprovedBy` — the change's CM approver(s), computed from the PR's own
# reviews/comments/merge via the shared cm-approvers.sh (same logic release-cm.sh aggregates).
#
# The block is rebuilt canonically from the known assessment keys (changeType, impact, risk,
# rationale) — the input file is NEVER echoed verbatim. Report-only keys (pr, title) and any
# other stray lines are dropped structurally, and every free-text value is encoded with jq so
# it stays a single YAML-safe line (a backtick / fence / newline cannot break out of the block).
#
# Env: REPO (default $GITHUB_REPOSITORY), GH_TOKEN (pull-requests: write), DRY_RUN, FORCE.
set -euo pipefail
log_err() { echo "::error::cm-assess-pr: $*" >&2; }
# Shared change-approver logic (is_bot, verify_person, pr_change_approvers) — same definition
# release-cm.sh uses, so the PR block's changeApprovedBy matches what the release aggregates.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cm-approvers.sh"
trap 'rm -f "${CM_PERSON_CACHE:-}"' EXIT

PR="${1:?usage: cm-assess-pr.sh <pr-number> [fields-file]}"
FILE="${2:-/dev/stdin}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
if [ "$FILE" != /dev/stdin ] && [ ! -r "$FILE" ]; then
  log_err "fields file not readable: $FILE"; exit 1
fi
fields=$(cat -- "$FILE")

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
yamlstr() { jq -Rn --arg s "$1" '$s'; }  # encode a scalar as a single YAML-safe double-quoted string
# Read one scalar for a key: first match, whitespace-trimmed, balanced-quote-stripped, inline
# `# comment` dropped only for unquoted values. Multi-line/block-scalar values collapse to their
# first line — which, combined with canonical rebuild, is why a crafted continuation cannot inject.
getv() {
  local raw val
  raw=$(printf '%s\n' "$fields" | grep -iE "^[[:space:]]*$1:" | head -1) || true
  [ -n "$raw" ] || { printf ''; return 0; }
  val=$(printf '%s' "${raw#*:}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$val" in
    '"'*'"') val=${val#\"}; val=${val%\"} ;;
    \'*\')   val=${val#\'}; val=${val%\'} ;;
    *)       val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//') ;;
  esac
  printf '%s' "$val"
}

# Reject an ambiguous/tampered blob: a well-formed assessment names each gating key once. This
# closes the "inject a second impact:/risk: line (e.g. via a multi-line title) that first-match
# then selects" path — a duplicate means we cannot trust which value is authoritative.
for k in changeType impact risk; do
  c=$(printf '%s\n' "$fields" | grep -cE "^[[:space:]]*$k:") || true
  [ "${c:-0}" -le 1 ] || { log_err "ambiguous assessment: '$k' appears ${c} times"; exit 2; }
done

imp=$(lc "$(getv impact)")
rsk=$(lc "$(getv risk)")
ctype=$(lc "$(getv changeType)")
rat=$(getv rationale)
case "$imp" in no-impact|unnoticeable|degradation|outage) ;; *) log_err "assessment needs a valid impact (got '${imp:-none}')"; exit 2;; esac
case "$rsk" in minor|major) ;; *) log_err "assessment needs a valid risk (got '${rsk:-none}')"; exit 2;; esac
case "$ctype" in ""|standard|normal|emergency) ;; *) log_err "assessment has an invalid changeType (got '$ctype')"; exit 2;; esac

pr_json=$(gh pr view "$PR" -R "$REPO" --json author,body,reviews,comments,mergedBy 2>/dev/null) \
  || { log_err "cannot read PR #$PR (check pull-requests scope / repo access)"; exit 1; }
body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
if printf '%s\n' "$body" | grep -qE '^[[:space:]]*cm-assessment: v1[[:space:]]*$' && [ -z "${FORCE:-}" ]; then
  echo "PR #$PR already has a cm-assessment block — leaving it (set FORCE=1 to add an updated one)"
  exit 0
fi
pr_author=$(printf '%s' "$pr_json" | jq -r '.author.login // ""')
# The change's CM approver(s): non-author human(s) who engaged with this PR and did not object
# (shared cm-approvers.sh — same logic release-cm.sh aggregates into the release changeApprovedBy).
# Computed AFTER the idempotent skip so a re-run over an already-decorated PR spends no API calls.
ca=""
while IFS=$'\t' read -r _lg _disp; do
  [ -n "$_lg" ] || continue
  ca="${ca:+$ca, }$(yamlstr "$_disp")"
done <<<"$(pr_change_approvers "$pr_json" "$pr_author")"

# Rebuild the block key-by-key from validated/encoded values — never echo the input verbatim.
block=$(
  printf '\n\n## Change Management\n\n```yaml\ncm-assessment: v1\n'
  [ -n "$ctype" ] && printf 'changeType: %s\n' "$ctype"
  printf 'impact: %s\n' "$imp"
  printf 'risk: %s\n' "$rsk"
  printf 'changeApprovedBy: [%s]\n' "$ca"
  [ -n "$rat" ] && printf 'rationale: %s\n' "$(yamlstr "$rat")"
  printf '```\n'
)
newbody="${body}${block}"
if [ -n "${DRY_RUN:-}" ]; then
  echo "=== DRY RUN: would append a cm-assessment block to PR #$PR (impact=$imp risk=$rsk) ==="
  printf '%s\n' "$block"
  exit 0
fi
gh pr edit "$PR" -R "$REPO" --body "$newbody" \
  || { log_err "failed to edit PR #$PR"; exit 1; }
echo "wrote cm-assessment to PR #$PR (impact=$imp risk=$rsk)"
