#!/usr/bin/env bash
# Idempotently write a cm-assessment block into a PULL REQUEST's description — used by the
# agent-driven audit backfill (`cmr` skill) to record an inferred assessment on a PR that
# was merged without one. release-cm.sh then aggregates it into the release.
#
# Usage: cm-assess-pr.sh <pr-number> [fields-file]   (fields on stdin if the file is omitted)
#   <fields-file> holds the block body WITHOUT the marker/fence, e.g.:
#     changeType: normal
#     impact: degradation
#     risk: major
#     scope: single-repo
#     rationale: "adds a DB migration; not auto-reversible"
#     backout: "revert migration 0042 and redeploy the prior release"
#
# Behaviour: appends a fenced `cm-assessment: v1` block under a `## Change Management`
# heading, preserving the rest of the PR body. Skips if the PR already has a block (a human
# or earlier run wrote one) unless FORCE=1. Validates impact + risk against the §3.1.1 enums.
#
# Env: REPO (default $GITHUB_REPOSITORY), GH_TOKEN (pull-requests: write), DRY_RUN, FORCE.
set -euo pipefail
log_err() { echo "::error::cm-assess-pr: $*" >&2; }

PR="${1:?usage: cm-assess-pr.sh <pr-number> [fields-file]}"
FILE="${2:-/dev/stdin}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
fields=$(cat -- "$FILE")

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
imp=$(lc "$(printf '%s\n' "$fields" | sed -nE 's/^[[:space:]]*impact:[[:space:]]*([^[:space:]#]+).*/\1/p' | head -1)")
rsk=$(lc "$(printf '%s\n' "$fields" | sed -nE 's/^[[:space:]]*risk:[[:space:]]*([^[:space:]#]+).*/\1/p' | head -1)")
case "$imp" in no-impact|unnoticeable|degradation|outage) ;; *) log_err "assessment needs a valid impact (got '${imp:-none}')"; exit 2;; esac
case "$rsk" in minor|major) ;; *) log_err "assessment needs a valid risk (got '${rsk:-none}')"; exit 2;; esac

# The audit persists one unified pr-<n>.yaml per PR (it also feeds the md report). Drop the
# report-only keys so only the assessment itself lands in the PR body's cm-assessment block.
fields=$(printf '%s\n' "$fields" | grep -vE '^[[:space:]]*(pr|title):' || true)

body=$(gh pr view "$PR" -R "$REPO" --json body -q .body 2>/dev/null) \
  || { log_err "cannot read PR #$PR (check pull-requests scope / repo access)"; exit 1; }
if printf '%s\n' "$body" | grep -qE '^[[:space:]]*cm-assessment: v1[[:space:]]*$' && [ -z "${FORCE:-}" ]; then
  echo "PR #$PR already has a cm-assessment block — leaving it (set FORCE=1 to add an updated one)"
  exit 0
fi

block=$(printf '\n\n## Change Management\n\n```yaml\ncm-assessment: v1\n%s\n```\n' "$fields")
newbody="${body}${block}"
if [ -n "${DRY_RUN:-}" ]; then
  echo "=== DRY RUN: would append a cm-assessment block to PR #$PR (impact=$imp risk=$rsk) ==="
  printf '%s\n' "$block"
  exit 0
fi
gh pr edit "$PR" -R "$REPO" --body "$newbody" \
  || { log_err "failed to edit PR #$PR"; exit 1; }
echo "wrote cm-assessment to PR #$PR (impact=$imp risk=$rsk)"
