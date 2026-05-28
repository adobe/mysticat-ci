# Lambda bundle-build pre-merge gate

This document describes the `bundle-build` opt-in input added to `service-ci.yaml`. It catches a class of Lambda failure that the existing lint + test + coverage steps miss: source-based unit tests stay green while the bundled artifact crashes at cold start.

## Why this exists

`service-ci.yaml`'s `build` job currently runs lint, test, coverage, and (optionally) docs lint/build. It does **not** run `npm run build` (= `hedy -v --test-bundle`). That gap let [SITES-45260](https://jira.corp.adobe.com/browse/SITES-45260) ship to production:

- `spacecat-api-service` `src/support/semrush/handlers/projects.js` read `data/locations.json` at module load via `readFileSync(import.meta.url)`.
- The JSON file was not declared in `package.json` `hlx.static`, so `helix-deploy` never copied it into the Lambda zip.
- Every cold start hit `ENOENT … data/locations.json`. The module's export went undefined. The deploy wrapper raised `TypeError: main2 is not a function` on every invocation.
- Source-based unit tests passed throughout: `import.meta.url` resolves to the original source path during tests, and the sibling JSON file is there. The failure only manifested in the bundled artifact.

`hedy --test-bundle` bundles, zips, imports the bundled `main`, and invokes `lambda()` against a synthetic healthcheck event — exiting non-zero on any non-2xx response. Running it pre-merge catches:

- Missing static assets (the SITES-45260 class).
- Top-level FS / network side-effects that work in source but fail in the bundle layout.
- Module-load `TypeError`s (broken dynamic imports, circular deps surfaced by the bundler, etc.).
- ESM/CJS interop regressions hidden by source resolution.

The repo-local version of this gate was first implemented in [`adobe/spacecat-api-service#2466`](https://github.com/adobe/spacecat-api-service/pull/2466). This PR lifts it into `mysticat-ci` so the remaining nine Lambda services inherit the same defence without each one re-implementing it.

## What's in scope

Nine SpaceCat services use the same bundling shape (`hedy ... --test-bundle`, VPC-attached, deployed via helix-deploy) and all consume `service-ci.yaml`:

- `spacecat-api-service`
- `spacecat-audit-worker`
- `spacecat-import-worker`
- `spacecat-content-scraper`
- `spacecat-content-processor`
- `spacecat-autofix-worker`
- `spacecat-fulfillment-worker`
- `spacecat-reporting-worker`
- `spacecat-jobs-dispatcher` (webpack variant — same `--test-bundle` flag)
- `spacecat-import-job-manager`

`mysticat-projector-service` consumes `service-ci.yaml` but bundles via `tsup`, not hedy — it stays opted out.

## Design

### Where the step lives

Inside the existing `build` job in `service-ci.yaml`, as a new step gated by an input:

- Same runner, same checkout, same Node + `npm ci` — no extra ~30–45 s of setup-per-job that a parallel job would cost.
- Runs after lint and test. If lint fails, bundle doesn't run. That's intentional: fix the cheaper problem first.
- Failure of the bundle step blocks the rest of the `build` job (docs, semantic-release-dry) — which is the right ordering, because a broken bundle would also fail the eventual deploy.

A separate job would let bundle-build run in parallel with lint+test but pays the install cost twice. The wallclock difference is small (sub-minute), the runner-minute cost is real, and the api-service repo-local pattern that serialized everything behind a separate `bundle-build` job is the shape we're explicitly walking back here.

### Input shape

```yaml
inputs:
  bundle-build:
    description: >
      Opt in to a Lambda bundle smoke check via `npm run build`
      (= helix-deploy `--test-bundle`). Bundles the Lambda artifact and
      invokes it against a synthetic healthcheck event. Catches module-load
      failures that source-based unit tests miss (missing static assets,
      `readFileSync(import.meta.url)` bundle drops, top-level FS/network
      access). Services that bundle with anything other than helix-deploy
      (e.g. tsup) should leave this off.
    default: false
    type: boolean
```

Default `false` keeps the change additive: every existing caller's CI continues to behave exactly as it does today until they opt in. There is no scenario where landing this PR can break a current caller.

### Dummy hedy env vars

`hedy` substitutes `${env.VPC_SUBNET_1}` etc. into `package.json` `hlx.*` fields at build time. All nine in-scope services declare `awsVpcSubnetIds`/`awsVpcSecurityGroupIds` in `hlx`, so the build step needs values present in the environment, but they don't need to be real — the bundle smoke test never talks to AWS. The step bakes hermetic dummies:

```yaml
env:
  VPC_SUBNET_1: subnet-00000000000000000
  VPC_SUBNET_2: subnet-00000000000000000
  VPC_SG_ID: sg-00000000000000000
  AWS_ACCOUNT_ID: '000000000000'
```

This matches the pattern proved out in `spacecat-api-service` PR #2466. It works on PRs that don't have access to environment-scoped secrets (forks, dependabot, contributors without `prod` env access).

If a future service needs additional build-time env vars baked into `hlx`, the fix lives **in this repo, not in the consuming service**. Open a PR against `mysticat-ci` that adds the new dummy to the `env:` block on this step — the change ships in the next `v2.x` release and every consumer picks it up via the floating `v2` tag. Putting the dummy in the consumer's CI yaml would not help: the bundle step runs inside the reusable workflow, where the consumer's env block isn't visible.

A build-time secret that genuinely cannot be dummied indicates a deeper problem (build steps should not need prod credentials), so the right answer there is usually to refactor the build, not to plumb a secret.

## Rollout

Three phases. Each phase is independent — pause between any of them if alignment falters.

### Phase 1: Land in mysticat-ci

This PR. After merge:

1. `release.yaml` auto-publishes the next semantic version (a `v2.x` minor, since the change is additive to the existing `v2` line).
2. The `v2` floating major tag advances automatically — every consumer pinned to `@v2` picks up the new input immediately, but the input defaults to `false` so behaviour is unchanged.

No deprecation of `v1`. Consumers stuck on `@v1` (none today, but in principle) continue to work.

### Phase 2: Opt in across the nine SpaceCat services

One PR per service. Each PR is two lines in `.github/workflows/ci.yaml`:

```diff
   ci:
     uses: adobe/mysticat-ci/.github/workflows/service-ci.yaml@v2
     with:
       service-name: <service>
+      bundle-build: true
       ...
     secrets: inherit
```

Suggested order (start with the highest-traffic / most-recently-burned services):

1. `spacecat-api-service` — and **delete the repo-local `bundle-build` job** in the same PR. Drop the `ci: needs: bundle-build` dependency so lint/test/coverage and bundle-build can interleave inside the reusable workflow.
2. `spacecat-audit-worker`
3. `spacecat-import-worker`
4. `spacecat-content-scraper`
5. `spacecat-content-processor`
6. `spacecat-autofix-worker`
7. `spacecat-fulfillment-worker`
8. `spacecat-reporting-worker`
9. `spacecat-jobs-dispatcher`
10. `spacecat-import-job-manager`

Each PR's verification is:

- Trigger CI on the PR.
- Confirm the new step ran (`Build Lambda bundle (smoke check)` appears in the build job log).
- Confirm exit 0.

If any service's bundle build is already broken when the gate first runs, that is the gate doing its job and a real bug to fix — not a reason to skip the rollout. The fix in that service's PR is part of the rollout.

### Phase 3 (optional, later): flip the default

Once all nine services have `bundle-build: true` for a quiet period (≥2 weeks, no surprises), consider a `v3` that defaults `bundle-build: true` and removes the per-service opt-in. `mysticat-projector-service` would explicitly set `bundle-build: false` since it doesn't bundle via helix-deploy.

Phase 3 is **not** in scope for this PR and not blocking. It is mentioned here only so consumers know the default may move.

## Out of scope

- **Action versioning for non-Lambda repos.** This input is a no-op when off; nothing changes for `mysticat-data-service`, `mystique`, `mysticat-projector-service`, or any other consumer.
- **Replacing `--test-bundle` with a custom healthcheck event.** `hedy`'s `testUrl` already points each service at `/_status_check/healthcheck.json` (or similar). Customising the event per service can be a follow-up if a service's bundle smoke check needs a different shape; today the helix-deploy default is sufficient.
- **Bundle-size diffing.** Catching bundle-size regressions is a separate concern; this gate is only about correctness, not size.
- **Caching the build output between jobs.** The bundle artifact produced here is throwaway; the real deploy artifact is built later by `semantic-release` against real env vars.

## Verification checklist

Before merging this PR:

- [ ] `service-ci.yaml` declares the new `bundle-build` input with `default: false`.
- [ ] The new step is gated by `if: inputs.bundle-build` and runs only when opted in.
- [ ] `README.md`'s Inputs table includes the new input.
- [ ] Existing callers (every spacecat service today) see no behaviour change in their next CI run after `v2` advances.

Before considering Phase 2 complete:

- [ ] All nine services have `bundle-build: true` merged.
- [ ] `spacecat-api-service` has its repo-local `bundle-build` job and `ci: needs: bundle-build` removed.
- [ ] No false positives reported (≥2 weeks of clean main-branch CI runs across all nine).
