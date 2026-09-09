#!/usr/bin/env bash
# should-run-heavy.sh — decide whether THIS invocation runs the heavy CI path
# (build + it-postgres), or lets its push/PR twin cover it.
#
# This is the authoritative, unit-tested spec for the push/PR dedup. The
# reusable workflow cannot run bash before it schedules a job (a job-level `if:`
# is evaluated pre-scheduling, and only relieving a runner slot pre-scheduling
# actually helps the org's concurrency pressure — a job that spins up just to
# decide "skip" has already taken its slot). So service-ci.yaml transcribes this
# decision into the `build` / `it-postgres` job `if:` expressions, and
# test-service-ci-dedup.sh pins those expressions to this matrix so the two
# cannot drift. Keep this script and those `if:` guards in lockstep.
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
