# ci-context — push/PR heavy-path dedup

For an open **same-repo** PR, GitHub fires both a `push` (`refs/heads/<branch>`)
and a `pull_request` (`refs/pull/N/merge`) event on every commit. `service-ci`'s
`concurrency` group keys on `github.ref` (which differs between the two), so the
runs never cancel and the heavy path — `build` + `it-postgres`, each ~5-7 min and
the branch-protection required checks — runs **twice per commit**, across ~10
consumers. That is the single biggest source of redundant runner-slot pressure on
the shared `adobe`-org pool.

The decision for whether one invocation runs the heavy path or lets its twin
cover it (the authoritative encoding is the job `if:` in `service-ci.yaml`;
`should-run-heavy.sh` is a readable, tested model of the same rule — see the
drift note below):

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
taken its slot). A workflow cannot run bash before scheduling, so the runtime
decision **must** be a declarative `if:` expression. That `if:` is the authority;
`should-run-heavy.sh` cannot be the runtime decider.

The three encodings and what actually ties them together (no overclaiming):
- the `build` / `it-postgres` job `if:` in `service-ci.yaml` — the runtime authority;
- `test-should-run-heavy.sh` proves `should-run-heavy.sh` reproduces the truth
  table above (a self-contained check of the model);
- `test-service-ci-dedup.sh` pins the YAML `if:` strings to a hardcoded `CLAUSE`
  literal by exact match — this is the **machine-enforced** drift guard: a YAML
  `if:` edit that diverges fails CI.

What is **not** machine-checked: the equivalence between `should-run-heavy.sh`
and the YAML `if:`. A GitHub-expression evaluator in bash is impractical, so
editing the script's logic does not automatically flag a now-stale YAML. Keep
the two in sync by review — change the decision in the script, the YAML `if:`,
and `CLAUSE` together.

## The load-bearing rule (learned the hard way)

The **push run is never the one to skip.** It uniquely carries `branch-deploy`
(feature-branch auto-deploy to `dev-branches`, push-only) and
`semantic-release` / `deploy` (main). `spacecat-api-service#3235` skipped the
push run to dedup and silently disabled branch-deploy for every developer. Only
the redundant **same-repo pull_request** copy of the heavy path is skippable;
fork PRs keep running it because they have no base-repo push twin. `T4`/`T5` in
`test-service-ci-dedup.sh` are permanent regression guards for this.

## Observability: the `dedup-notice` breadcrumb

When the dedup skips `build` + `it-postgres` on a same-repo `pull_request` run,
those checks show as `skipped` on the PR with no hint of where the real run is.
The `dedup-notice` job in `service-ci.yaml` closes that gap: it runs in exactly
the deduped case (the De Morgan negation of the heavy-path `if:` - dedup on AND
`pull_request` AND same-repo) and prints a `::notice` annotation stating that
`build` + `it-postgres` run on the branch's `push` event for the same commit and
report the required checks there. So a developer reads "expected, covered by the
push run" rather than suspecting a silent failure. It is not a required check, it
never runs when dedup is off (the default) or on a `push`/`workflow_dispatch`/fork
PR, and it is pinned by `T6` in `test-service-ci-dedup.sh` (mutation-tested to
fail closed if the job is removed or its gate broadened).

## Enabling it on a consumer (opt-in)

`dedup-pr-runs` defaults **false**, so nothing changes until a repo passes
`dedup-pr-runs: true` to `service-ci.yaml`.

The load-bearing assumption to verify (not settled here): when dedup skips the
same-repo `pull_request` copy of a heavy job, that job's `pull_request` run
reports a `skipped` check while the branch's `push` run reports a real success —
two runs of the same check name on the same head SHA. This relies on GitHub
(a) treating a job-level `skipped` required check as satisfied, and (b) counting
the push run's success on the PR head SHA. Both are standard GitHub behavior, but
confirm them on a live PR per repo before trusting them. Before flipping it on:

1. Confirm the repo's branch-protection required checks are exactly `ci / build`
   and `ci / it-postgres` (or whatever the heavy jobs are named for that caller).
2. Confirm the caller runs `service-ci` on **feature-branch `push`**, not only on
   `pull_request`. This is what produces the covering success. A caller that runs
   only on `pull_request` has **no push twin**: under dedup the same-repo PR's
   heavy check is `skipped` with nothing covering it, and a skipped required check
   auto-satisfies branch protection — so the heavy path silently never ran
   (silent-green). Any such caller already has `branch-deploy` broken (also
   push-only), so this is unlikely, but check it explicitly.
3. On the **first** live PR after enabling, verify the required checks report
   **green from the push run** (check *which* run produced the green, not just
   that it is green — the same-repo `pull_request` copies will show as skipped).
   If a required check hangs `pending` instead, the push run is not reporting it
   on the PR head SHA for that repo — revert the flag and investigate before
   rollout.
