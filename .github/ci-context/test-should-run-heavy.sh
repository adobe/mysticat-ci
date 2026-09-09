#!/usr/bin/env bash
# Tests for should-run-heavy.sh — the push/PR dedup decision.
#
# The heavy path (build + it-postgres) is the expensive, required part of a CI
# run. For an open same-repo PR, GitHub fires BOTH a push (refs/heads/<branch>)
# and a pull_request (refs/pull/N/merge) event, and the reusable workflow's
# concurrency group keys on github.ref (which differs), so the two runs never
# cancel — the heavy path runs twice per commit. This decides, for a single
# invocation, whether that invocation should run the heavy path or let the twin
# run cover it.
#
# The load-bearing rule learned the hard way (spacecat-api-service#3235, which
# silently disabled branch-deploy): the PUSH run is never the one to skip — it
# uniquely carries branch-deploy (feature branches) and semantic-release/deploy
# (main). Only the redundant SAME-REPO pull_request copy may be skipped. Fork
# PRs have no base-repo push run, so they must still run the heavy path on
# pull_request.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/should-run-heavy.sh"

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; shift; printf '%s\n' "$*" | sed 's/^/      /'; fail=$((fail+1)); }

# decide DEDUP_ENABLED EVENT_NAME HEAD_REPO BASE_REPO -> prints "run"|"skip"
decide(){
  DEDUP_ENABLED="$1" EVENT_NAME="$2" HEAD_REPO="$3" BASE_REPO="$4" bash "$SCRIPT"
}
BASE='adobe/spacecat-api-service'

# --- dedup DISABLED: today's behavior, always run (regression guard for the
#     default-off contract — no consumer changes until it opts in) ---
[ "$(decide false pull_request "$BASE" "$BASE")" = run ] \
  && ok "T1 dedup off + same-repo PR -> run (unchanged behavior)" || no "T1" "got $(decide false pull_request "$BASE" "$BASE")"
[ "$(decide false push '' "$BASE")" = run ] \
  && ok "T2 dedup off + push -> run" || no "T2" "got $(decide false push '' "$BASE")"

# --- dedup ENABLED ---
# The branch-deploy regression guard: a feature-branch PUSH must ALWAYS run the
# heavy path, because branch-deploy (push-only) needs build+it-postgres to gate
# its deploy. Skipping this is exactly the #3235 bug.
[ "$(decide true push '' "$BASE")" = run ] \
  && ok "T3 dedup on + push -> run (branch-deploy/main gates need heavy)" || no "T3" "got $(decide true push '' "$BASE")"

# workflow_dispatch (manual) has no PR twin to dedup against -> run.
[ "$(decide true workflow_dispatch '' "$BASE")" = run ] \
  && ok "T4 dedup on + workflow_dispatch -> run" || no "T4" "got $(decide true workflow_dispatch '' "$BASE")"

# same-repo PR: the push run covers it -> skip the redundant copy (the win).
[ "$(decide true pull_request "$BASE" "$BASE")" = skip ] \
  && ok "T5 dedup on + same-repo PR -> skip (deduped)" || no "T5" "got $(decide true pull_request "$BASE" "$BASE")"

# fork PR: no push run exists in the base repo -> must run heavy on pull_request.
[ "$(decide true pull_request 'contributor/spacecat-api-service' "$BASE")" = run ] \
  && ok "T6 dedup on + fork PR -> run (no base-repo push twin)" || no "T6" "got $(decide true pull_request 'contributor/spacecat-api-service' "$BASE")"

# defensive: a PR event with an empty head repo (deleted fork head) errs toward
# running rather than silently skipping a required check.
[ "$(decide true pull_request '' "$BASE")" = run ] \
  && ok "T7 dedup on + PR with empty head repo -> run (fail-safe)" || no "T7" "got $(decide true pull_request '' "$BASE")"

# the DEDUP_ENABLED flag is strict: only the literal "true" enables dedup, so a
# misspelled/blank input can never silently drop a required PR check.
[ "$(decide '' pull_request "$BASE" "$BASE")" = run ] \
  && ok "T8 empty dedup flag -> treated as off -> run" || no "T8" "got $(decide '' pull_request "$BASE" "$BASE")"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
