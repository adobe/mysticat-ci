#!/usr/bin/env bash
# Golden / drift guard: pins the push/PR dedup wiring in service-ci.yaml to the
# unit-tested decision in should-run-heavy.sh (which test-should-run-heavy.sh
# proves as a truth table). A job-level `if:` is evaluated before the job is
# scheduled, so it cannot call the bash spec at runtime — this test is what
# stops the transcribed `if:` guards from drifting away from the tested matrix,
# and what stops the spacecat-api-service#3235 branch-deploy regression from
# ever being re-introduced in the shared workflow.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
YAML="$HERE/../../workflows/service-ci.yaml"

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; shift; printf '%s\n' "$*" | sed 's/^/      /'; fail=$((fail+1)); }
has(){ grep -qF "$1" "$YAML"; }

# The one canonical dedup clause. build runs unless (dedup AND same-repo PR);
# it is exactly the "skip only a same-repo pull_request copy" rule from
# should-run-heavy.sh. Every guard below must use this literal, verbatim.
CLAUSE="!inputs.dedup-pr-runs || github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository"

# T1 the opt-in input exists and defaults OFF (no consumer changes behavior
#    until it verifies required checks on a live PR and flips this).
{ has 'dedup-pr-runs:' \
  && awk '/dedup-pr-runs:/{f=1} f&&/default:/{print;exit}' "$YAML" | grep -qF 'default: false'; } \
  && ok "T1 dedup-pr-runs input present, default false" || no "T1" "input missing or not default false"

# T2 build carries exactly the canonical clause.
has "    if: \"$CLAUSE\"" \
  && ok "T2 build if == canonical dedup clause" || no "T2" "build if missing/altered"

# T3 it-postgres keeps its own gate AND adds the canonical clause (parenthesised).
has "    if: \"inputs.it-postgres && ($CLAUSE)\"" \
  && ok "T3 it-postgres if == it-postgres gate AND dedup clause" || no "T3" "it-postgres if missing/altered"

# T4 REGRESSION GUARD: branch-deploy must still fire on push (feature branches),
#    which is what carries it. Dropping this is the #3235 bug.
has "    if: \"!failure() && !cancelled() && github.event_name == 'push' && github.ref != 'refs/heads/main'\"" \
  && ok "T4 branch-deploy still push-gated (branch-deploy preserved)" || no "T4" "branch-deploy push gate changed"

# T5 REGRESSION GUARD: branch-deploy must NOT be gated on dedup — it runs on the
#    push event, which dedup never skips. If dedup ever leaks into branch-deploy
#    the whole point (keep branch-deploy) is lost.
bd_if=$(awk '/^  branch-deploy:/{f=1} f{print} f&&/^  [a-z]/&&!/^  branch-deploy:/{exit}' "$YAML" | grep -m1 'if:')
case "$bd_if" in
  *dedup-pr-runs*) no "T5" "branch-deploy if references dedup-pr-runs: $bd_if" ;;
  *) ok "T5 branch-deploy if is independent of dedup" ;;
esac

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
