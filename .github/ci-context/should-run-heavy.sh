#!/usr/bin/env bash
# should-run-heavy.sh — an illustrative, unit-tested MODEL of the push/PR dedup
# decision: whether THIS invocation runs the heavy CI path (build + it-postgres)
# or lets its push/PR twin cover it.
#
# NOT the runtime authority. The reusable workflow cannot run bash before it
# schedules a job (a job-level `if:` is evaluated pre-scheduling, and only
# relieving a runner slot pre-scheduling actually helps the org's concurrency
# pressure — a job that spins up just to decide "skip" has already taken its
# slot). So the authoritative decision AT RUNTIME is the declarative `build` /
# `it-postgres` job `if:` in service-ci.yaml. This script is an executable
# statement of the same decision, kept readable and regression-tested
# (test-should-run-heavy.sh) because getting it wrong caused a prod incident
# (spacecat-api-service#3235).
#
# Two drift facts, stated honestly (do not overclaim "cannot drift"):
#   - test-service-ci-dedup.sh pins the YAML `if:` strings to a hardcoded CLAUSE
#     literal (MACHINE-enforced): a YAML `if:` edit that diverges fails CI.
#   - This script's equivalence to that YAML `if:` is maintained by REVIEW, not
#     by a check — a GitHub-expression evaluator in bash is impractical, so
#     editing the logic here does NOT automatically flag a now-stale YAML. If you
#     change the decision, update all three together: this script, the `build` /
#     `it-postgres` `if:` in service-ci.yaml, and CLAUSE in test-service-ci-dedup.sh.
#
# Inputs (env):
#   DEDUP_ENABLED  "true" to dedup; anything else = off (today's behavior)
#   EVENT_NAME     github.event_name (push | pull_request | workflow_dispatch)
#   HEAD_REPO      github.event.pull_request.head.repo.full_name ("" if non-PR)
#   BASE_REPO      github.repository
# Output: "run" or "skip" on stdout.
set -uo pipefail

DEDUP_ENABLED="${DEDUP_ENABLED:-}"
EVENT_NAME="${EVENT_NAME:-}"
HEAD_REPO="${HEAD_REPO:-}"
BASE_REPO="${BASE_REPO:-}"

# Dedup off (default) -> always run. Strict "true" match so a blank or
# misspelled flag can never silently drop a required PR check.
if [ "$DEDUP_ENABLED" != "true" ]; then
  echo run
  exit 0
fi

# push carries branch-deploy (feature branches) and semantic-release/deploy
# (main); workflow_dispatch is manual with no PR twin. Neither may be skipped.
if [ "$EVENT_NAME" != "pull_request" ]; then
  echo run
  exit 0
fi

# Fork PR: no push run exists in the base repo, so the pull_request run is the
# only one that can report the required checks -> run. (An empty HEAD_REPO also
# lands here and errs toward running.)
if [ "$HEAD_REPO" != "$BASE_REPO" ]; then
  echo run
  exit 0
fi

# Same-repo PR: the branch push already runs the heavy path on the same head
# SHA -> skip the redundant copy.
echo skip
