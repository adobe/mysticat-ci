#!/usr/bin/env bash
# CI safety-net for PRs targeting a deploy branch: ensure the PR carries a cm-assessment block so
# the release aggregation has per-PR CM info. If the PR already has a block (author/agent via the
# `cmr` skill), leave it untouched. Otherwise write a BASELINE — standard / unnoticeable / minor —
# escalated to normal / degradation / major when the `cmr:high-risk` label is present (the same
# escalate-only signal release-cm.sh uses). Delegates the actual write to cm-assess-pr.sh (canonical
# block, idempotent). Read-only to everything except the PR body; makes no ServiceNow calls.
#
# Usage: cm-assess-pr-auto.sh <pr-number>
# Env: REPO (default $GITHUB_REPOSITORY), GH_TOKEN (pull-requests: write), DRY_RUN, FORCE.
set -euo pipefail
log_err() { echo "::error::cm-assess-pr-auto: $*" >&2; }

PR="${1:?usage: cm-assess-pr-auto.sh <pr-number>}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
HERE=$(cd "$(dirname "$0")" && pwd)

body=$(gh pr view "$PR" -R "$REPO" --json body -q .body 2>/dev/null) \
  || { log_err "cannot read PR #$PR (check pull-requests scope / repo access)"; exit 1; }
if printf '%s\n' "$body" | grep -qE '^[[:space:]]*cm-assessment: v1[[:space:]]*$' && [ -z "${FORCE:-}" ]; then
  echo "PR #$PR already has a cm-assessment block — leaving it (author/agent assessment wins)"
  exit 0
fi

# The cmr:high-risk label is the escalate-only floor (mirrors release-cm.sh). No label => baseline.
labels=$(gh pr view "$PR" -R "$REPO" --json labels -q '.labels[].name' 2>/dev/null || true)
if printf '%s\n' "$labels" | grep -qxF 'cmr:high-risk'; then
  ct=normal; im=degradation; rk=major
  rat="Auto-added from the cmr:high-risk label at CI time; confirm the specifics via the cmr skill."
else
  ct=standard; im=unnoticeable; rk=minor
  rat="Auto-added baseline (no PR assessment present at CI time); refine via the cmr skill if this change is higher-impact."
fi
echo "PR #$PR has no assessment — writing ${im}/${rk} (${ct})"

printf 'changeType: %s\nimpact: %s\nrisk: %s\nrationale: "%s"\n' "$ct" "$im" "$rk" "$rat" \
  | REPO="$REPO" bash "$HERE/cm-assess-pr.sh" "$PR"
