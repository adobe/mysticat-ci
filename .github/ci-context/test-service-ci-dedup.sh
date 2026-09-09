#!/usr/bin/env bash
# Golden / drift guard: the MACHINE-enforced pin on the push/PR dedup wiring in
# service-ci.yaml. It asserts the runtime-authoritative `build` / `it-postgres`
# job `if:` strings equal a hardcoded CLAUSE (the same decision documented in
# should-run-heavy.sh + its truth table) and that branch-deploy keeps its push
# gate. A job-level `if:` is evaluated before scheduling, so it cannot call any
# bash at runtime — this exact-string pin is what stops the YAML `if:` from
# drifting, and what stops the spacecat-api-service#3235 branch-deploy
# regression from ever being re-introduced in the shared workflow.
#
# Scope of the guarantee (do not overclaim): this pins the YAML `if:` STRINGS
# only. It does NOT evaluate GitHub-expression semantics, and it does NOT
# cross-check should-run-heavy.sh — the script stays equivalent to the YAML by
# review, not by this test.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
YAML="$HERE/../workflows/service-ci.yaml"

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; shift; printf '%s\n' "$*" | sed 's/^/      /'; fail=$((fail+1)); }
has(){ grep -qF "$1" "$YAML"; }

# The one canonical dedup clause. build runs unless (dedup AND same-repo PR);
# it is exactly the "skip only a same-repo pull_request copy" rule from
# should-run-heavy.sh. Every guard below must use this literal, verbatim.
# LOCKSTEP: if you change the decision, update this CLAUSE, the `build` /
# `it-postgres` `if:` in service-ci.yaml, AND should-run-heavy.sh together — the
# script is not machine-tied to the YAML (see the header note).
CLAUSE="!inputs.dedup-pr-runs || github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository"

# T1 the opt-in input exists and defaults OFF (no consumer changes behavior
#    until it verifies required checks on a live PR and flips this).
{ has 'dedup-pr-runs:' \
  && awk '/dedup-pr-runs:/{f=1} f&&/default:/{print;exit}' "$YAML" | grep -qF 'default: false'; } \
  && ok "T1 dedup-pr-runs input present, default false" || no "T1" "input missing or not default false"

# T2 build carries exactly the canonical clause. This is an EXACT-string pin by
#    design: a semantically identical reformat (e.g. changing the `if:` quote
#    style) will fail it, and that is intended — a reformat must update CLAUSE
#    here to match.
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
# Extract branch-deploy's JOB-LEVEL `if:` specifically: the first 4-space `if:`
# after the `branch-deploy:` header and before the job's `steps:`. Grabbing the
# first `if:` in the whole block would instead catch a STEP-level `if:` (e.g.
# `steps.main-check...`) and false-pass if the job-level one were removed — the
# exact hole a plain `grep -m1 if:` left. Empty extraction => fail closed.
bd_if=$(awk '
  /^  branch-deploy:/ {f=1; next}
  f && /^  [a-z]/     {exit}        # next job header -> stop
  f && /^    steps:/  {exit}        # reached steps -> job-level if: already passed
  f && /^    if:/     {print; exit} # the job-level if: line
' "$YAML")
if [ -z "$bd_if" ]; then
  no "T5" "could not locate branch-deploy JOB-LEVEL if: (renamed/reindented/removed?)"
else
  case "$bd_if" in
    *dedup-pr-runs*) no "T5" "branch-deploy if references dedup-pr-runs: $bd_if" ;;
    *) ok "T5 branch-deploy job-level if: is independent of dedup" ;;
  esac
fi

# T6 OBSERVABILITY BREADCRUMB: a `dedup-notice` job must surface a notice on the
#    same-repo `pull_request` run whose heavy path was deduped, so a developer
#    seeing `ci / build` + `ci / it-postgres` as `skipped` knows the push run
#    covers them (not a silent failure). Its `if:` is the De Morgan negation of
#    CLAUSE -- it runs in exactly the case the heavy jobs skip: dedup on AND
#    pull_request AND same-repo. If you change CLAUSE, change this in lockstep.
SKIP_CLAUSE="inputs.dedup-pr-runs && github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository"
if has 'dedup-notice:' && has "    if: \"$SKIP_CLAUSE\""; then
  # Scope the payload check to the dedup-notice JOB BLOCK and require the emitted
  # command (`echo "::notice`), NOT a bare `::notice` anywhere in the file: the
  # job's own comment contains the word `::notice`, so a whole-file grep
  # false-passes when the echo is removed (mutation testing caught exactly this).
  # Extract from the job header to the next 2-space job header.
  notice_block=$(awk '
    /^  dedup-notice:/ {f=1; print; next}
    f && /^  [a-z]/    {exit}          # next job header -> stop
    f                  {print}
  ' "$YAML")
  if printf '%s\n' "$notice_block" | grep -qF 'echo "::notice'; then
    ok "T6 dedup-notice job present, gated to the deduped case, emits a ::notice"
  else
    no "T6" "dedup-notice job present but its step emits no ::notice breadcrumb"
  fi
else
  no "T6" "dedup-notice missing or its if: != skip clause (De Morgan negation of CLAUSE)"
fi

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
