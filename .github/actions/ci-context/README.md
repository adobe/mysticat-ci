# ci-context — push/PR heavy-path dedup

For an open **same-repo** PR, GitHub fires both a `push` (`refs/heads/<branch>`)
and a `pull_request` (`refs/pull/N/merge`) event on every commit. `service-ci`'s
`concurrency` group keys on `github.ref` (which differs between the two), so the
runs never cancel and the heavy path — `build` + `it-postgres`, each ~5-7 min and
the branch-protection required checks — runs **twice per commit**, across ~10
consumers. That is the single biggest source of redundant runner-slot pressure on
the shared `adobe`-org pool.

`should-run-heavy.sh` is the authoritative decision for whether one invocation
runs the heavy path or lets its twin cover it:

| dedup-pr-runs | event | PR head repo | decision |
|---|---|---|---|
| off (default) | any | any | **run** (today's behavior, unchanged) |
| on | push | — | **run** (carries branch-deploy + main deploy gates) |
| on | workflow_dispatch | — | **run** (manual; no PR twin) |
| on | pull_request | fork (`head != base`) | **run** (no base-repo push twin) |
| on | pull_request | same-repo | **skip** (the push run covers it) |

## Why the decision lives in a job `if:`, and why this script exists anyway

A job-level `if:` is evaluated **before** the job is scheduled, so a skipped job
never takes a runner slot — that is the only thing that relieves the org's
concurrency pressure (a job that spins up merely to decide "skip" has already
taken its slot). A workflow cannot run bash before scheduling, so the decision
**must** be a declarative `if:` expression, and this bash spec cannot be the
runtime decider.

So `service-ci.yaml` transcribes this matrix into the `build` / `it-postgres`
job `if:` guards, and `test-service-ci-dedup.sh` pins those guards to this matrix
(exact-match) so the two cannot silently drift. `test-should-run-heavy.sh` proves
the matrix itself as a truth table.

## The load-bearing rule (learned the hard way)

The **push run is never the one to skip.** It uniquely carries `branch-deploy`
(feature-branch auto-deploy to `dev-branches`, push-only) and
`semantic-release` / `deploy` (main). `spacecat-api-service#3235` skipped the
push run to dedup and silently disabled branch-deploy for every developer. Only
the redundant **same-repo pull_request** copy of the heavy path is skippable;
fork PRs keep running it because they have no base-repo push twin. `T4`/`T5` in
`test-service-ci-dedup.sh` are permanent regression guards for this.

## Enabling it on a consumer (opt-in)

`dedup-pr-runs` defaults **false**, so nothing changes until a repo passes
`dedup-pr-runs: true` to `service-ci.yaml`. Before flipping it on:

1. Confirm the repo's branch-protection required checks are exactly `ci / build`
   and `ci / it-postgres` (or whatever the heavy jobs are named for that caller).
2. On the **first** live PR after enabling, verify those required checks report
   **green from the push run** (the same-repo `pull_request` copies will show as
   skipped — that is expected and, for job-level skips, satisfies branch
   protection). If a required check hangs `pending` instead, the push run is not
   reporting it on the PR head SHA for that repo — revert the flag and
   investigate before rollout.
