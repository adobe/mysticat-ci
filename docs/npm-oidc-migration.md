# npm OIDC Trusted Publishers — consumer migration

This document is the per-consumer migration guide for moving the npm publish
path in `service-ci.yaml` from `ADOBE_BOT_NPM_TOKEN` to npm Trusted Publishers
(OIDC). The migration is opt-in per consumer via the `npm-oidc-enabled` input.

Baseline implementation reference: `adobe/spacecat-shared` PR #1592.

## Why migrate

- **Eliminates a long-lived org secret.** `ADOBE_BOT_NPM_TOKEN` is shared
  across ~15 adobe-org repos and silently rots on rotation/expiry/2FA
  events; the failure surfaces only on the next release.
- **Sigstore provenance.** Every publish carries a SLSA v1 attestation
  proving the published tarball was built from `main` in this repo via
  this exact workflow.
- **Per-package scoping.** Trust binding ties the npm package to the
  caller repo's workflow path; a compromise of another consumer cannot
  republish your package.

## Workflow contract

The reusable workflow now accepts:

```yaml
uses: adobe/mysticat-ci/.github/workflows/service-ci.yaml@v3
with:
  service-name: my-service
  npm-oidc-enabled: true   # opt in to OIDC publishing
```

When `npm-oidc-enabled: true`:

- Dry-run runs with `SR_NO_NPM_AUTH=true` and `NPM_TOKEN` genuinely unset
  (the legacy-mode `NPM_TOKEN` injection step is skipped). The fact that
  it is unset and not the empty string matters: an empty `NPM_TOKEN` can
  suppress OIDC fallback in some npm releases.
- Release runs with `NPM_CONFIG_PROVENANCE=true`, `NPM_TOKEN` unset, and
  `environment: npm-publish` (or `prod` if `vpc-enabled: true` — see
  environment selection below).
- An OIDC preflight step asserts the GitHub Environment exists with a
  main-only `deployment_branch_policy` before publish — failing fast if
  the consumer-side env-protection setup is missing.
- An "Update NPM" step installs `npm@11.13.0` to satisfy the OIDC floor
  (`npm >= 11.5.1`), with a retry loop and an explicit version assertion
  so a silently-failed upgrade cannot publish under an unsupported npm.
- A "Verify OIDC publish identity" step asserts the latest publish's
  `_npmUser` is `"GitHub Actions"`, failing loud if a token publish
  somehow occurred.

When `npm-oidc-enabled: false` (default): unchanged. Existing consumers
keep token-based publishing until they explicitly opt in.

## Per-consumer code changes

### 1. `.releaserc.cjs` — gate `@semantic-release/npm`

```js
module.exports = {
  // ...
  plugins: [
    // ...
    ...(process.env.SR_NO_NPM_AUTH === 'true' ? [] : ['@semantic-release/npm']),
    // ...
  ],
};
```

**Strict equality matters.** A truthy check (`process.env.SR_NO_NPM_AUTH`)
returns true for the strings `"false"`, `"0"`, and `"no"` — strict
`=== 'true'` is the only safe form.

This guard is safe to land BEFORE flipping `npm-oidc-enabled`; the env var
is unset by default, so the plugin still loads in legacy mode.

### 2. `package.json` — bump npm engines

```json
{
  "engines": {
    "node": ">=22.0.0 <25.0.0",
    "npm": ">=11.5.1 <12.0.0"
  }
}
```

### 3. Caller workflow — flip the input

```yaml
# .github/workflows/main.yaml (or whatever your caller is named)
jobs:
  ci:
    uses: adobe/mysticat-ci/.github/workflows/service-ci.yaml@v3
    with:
      service-name: my-service
      npm-oidc-enabled: true
```

## Per-consumer server-side setup

### 4. Create the `npm-publish` GitHub Environment

Settings → Environments → `New environment` → name `npm-publish`. Configure:

- **`can_admins_bypass: false`** — admins must NOT be able to skip the env policy.
- **Deployment branch policy** → selected branches → add `main`. The
  reusable workflow's OIDC preflight asserts that **only** `main` is
  allowed; adding additional branches (e.g. `release/*`) will fail the
  preflight even if `main` is also present.
- Required reviewers: optional. See "Reviewer policy" below.

VPC consumers should ensure `main` is the only entry on their existing
`prod` environment's branch policy — the OIDC binding will use
`--environment prod` instead of `npm-publish`. If `prod` already permits
additional branches for AWS deploy reasons, this is incompatible with
the OIDC security model and the consumer should either split into a
separate env or restrict `prod` to `main`-only.

**Token permission requirement for the preflight check:**
`ADOBE_BOT_GITHUB_TOKEN` (used by the reusable workflow to read the
consumer's env settings during the OIDC preflight) needs at least
`Administration: read` on the consumer repo — the `/environments`
endpoints are NOT readable with `repo` scope alone on fine-grained PATs.
If the preflight fails with a 403/404 on a freshly-created env, the
token's permission level is the first thing to verify.

### 5. Tighten branch protection on `main`

Required for the OIDC security model:

| Setting | Value |
|---|---|
| `required_pull_request_reviews.required_approving_review_count` | ≥ 1 |
| `required_pull_request_reviews.dismiss_stale_reviews` | true |
| `required_pull_request_reviews.require_last_push_approval` | true |
| `enforce_admins` | true |
| `allow_force_pushes` | false |
| `allow_deletions` | false |
| `required_status_checks.contexts` | contains the CI's `Test` context |
| `bypass_pull_request_allowances` | exactly `["adobe-bot"]`, no teams, no apps |

### 6. Register npm Trusted Publisher bindings

For each `@adobe/*` package your repo publishes, as `adobe-bot`:

```bash
# Prereqs:
npm install -g npm@11.13.0
npm login                       # as adobe-bot
gh auth login                   # for the next step

# Bind each package to THIS REPO's caller workflow path.
# CRITICAL: bind to YOUR repo's workflow file, NOT mysticat-ci/service-ci.yaml.
# Binding to the reusable workflow would let any other consumer publish your
# package (the trust binding allows any caller whose workflow_ref matches).
npm trust github @adobe/<your-package> \
  --repository adobe/<your-repo> \
  --file <your-caller-workflow-filename.yaml> \
  --environment npm-publish \
  --yes
```

If `vpc-enabled: true`: use `--environment prod` instead, since the workflow
will mint the OIDC token with the `prod` env claim.

Pace requests by ~2 seconds when registering many packages to avoid registry
rate-limiting.

Verify registration:

```bash
npm trust list @adobe/<your-package>
```

### 7. Verify the first release

After the first OIDC publish on `main`:

```bash
npm view @adobe/<your-package> dist.attestations
# Expect: a JSON object with `url` pointing at
# https://registry.npmjs.org/-/npm/v1/attestations/...
npm view @adobe/<your-package> _npmUser
# Expect: "GitHub Actions" (not adobe-admin)
```

The SLSA attestation should encode:

- `workflow.ref: refs/heads/main`
- `workflow.repository: https://github.com/adobe/<your-repo>`
- `workflow.path: .github/workflows/<your-caller-workflow>.yaml`

If the workflow path in the attestation points at
`adobe/mysticat-ci/.github/workflows/service-ci.yaml`, the binding was
registered against the reusable workflow (insecure) — re-register against
the caller's workflow path.

## Reviewer policy

Whether the `npm-publish` env requires human approval is a per-consumer
operational choice. Branch protection on `main` already provides the
load-bearing PR-review gate; the env-reviewer rule is a release-stamp on
a decision already made. For a service that releases on every merge, the
env-reviewer requirement tends to be a single-timezone bottleneck.

To run without a reviewer gate (typical):

- Don't add `required_reviewers` to the env's protection rules.
- The OIDC token's `environment` claim is still server-enforced via the
  `main`-only `deployment_branch_policy`.

To add a reviewer gate later (note: the `PUT environments` API replaces
the entire `deployment_branch_policy`, so `main` must be re-added
explicitly afterwards):

```bash
cat <<'EOF' | gh api -X PUT repos/adobe/<your-repo>/environments/npm-publish --input -
{
  "wait_timer": 0,
  "prevent_self_review": true,
  "reviewers": [{ "type": "Team", "id": <team-id> }],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
EOF

# Re-add 'main' to the custom branch list (cleared by the PUT above):
gh api -X POST "repos/adobe/<your-repo>/environments/npm-publish/deployment-branch-policies" \
  -f name=main
```

`prevent_self_review` MUST be `true` whenever `reviewers` is non-empty.

## Rollback

The contract is designed so that **every backwards transition is a single
flag flip**. `ADOBE_BOT_NPM_TOKEN` should be retained as an org secret
for at least 2 successful OIDC releases per consumer before rotation —
but see the Phase 4 forcing function: laggards who fail to migrate by
the deadline (target date + 60 days) have the secret revoked regardless
of whether they crossed the per-consumer 2-cycle threshold. The 2-cycle
gate is the preferred signal; the deadline is the backstop that prevents
the rollout from stalling indefinitely.

### Rollback scenario A — Consumer-side rollback (after opting in)

Symptom: a consumer flipped `npm-oidc-enabled: true`, one or more releases
ran on OIDC, then a regression / outage / policy reversal makes the token
path preferable again.

Procedure (single PR on the consumer repo):

1. Edit the caller workflow: change `npm-oidc-enabled: true` → `false` (or
   remove the input entirely — default is `false`).
2. Merge. The next push to `main` uses the legacy `NPM_TOKEN` path
   automatically — the workflow's conditional expressions select the
   legacy branch when the input is unset/false:

   | Knob | OIDC mode | Legacy mode (rollback) |
   |---|---|---|
   | `NPM_TOKEN` env on dry-run + release | UNSET (gated step skipped) | injected via `$GITHUB_ENV` from `secrets.ADOBE_BOT_NPM_TOKEN` |
   | `SR_NO_NPM_AUTH` env on dry-run | `'true'` | `''` (unset) |
   | `NPM_CONFIG_PROVENANCE` env on release | `'true'` | `''` (unset) |
   | `environment:` claim | `npm-publish` (or `prod` if vpc-enabled) | `prod` if vpc-enabled, else none |
   | "Update NPM" step | runs (`npm@11.13.0`, version-asserted) | skipped |
   | OIDC preflight | runs (env policy + npm floor) | skipped |
   | "Verify OIDC publish identity" | runs (`_npmUser` must be `"GitHub Actions"`) | skipped |

3. Nothing else needs reverting:

   - The `.releaserc.cjs` `SR_NO_NPM_AUTH === 'true'` guard is a no-op
     when the env var is unset. Leave it in place. (It's also still
     compatible with the legacy path because `@semantic-release/npm`
     loads exactly as before.)
   - `engines.npm: >=11.5.1` in `package.json` is harmless to keep — npm
     11 is backward-compatible with the legacy publish flow.
   - npm trust bindings on npmjs.com are non-blocking for token-based
     publishes. They sit there inert until you re-enable OIDC.
   - The `npm-publish` GitHub Environment (and any branch-protection
     tightening) is harmless to leave in place.

This is intentionally a one-line rollback. Audit the OIDC failure
(provenance issue, trust binding drift, sigstore outage, etc.) on its
own pace after the legacy path is restored.

### Rollback scenario B — mysticat-ci PR-level rollback

Symptom: this PR caused a regression for a default-false consumer (no
consumer is supposed to be affected, but if e.g. a YAML expression evaluates
unexpectedly under legacy mode on some runner).

Procedure: `git revert <merge-sha>` and cut a hotfix `v3.0.1` (or do not
cut `v3` at all and require consumers to remain on `@v2`). Default-false
means no consumer that hasn't explicitly opted in should be affected; if
one is, the revert PR restores the prior `service-ci.yaml` verbatim.

Backwards-compatibility surfaces audited as part of this PR (see the
"Self-review" section below) — all default-false code paths produce
identical behavior to the pre-PR workflow.

### Rollback scenario C — Permanent revert post-rotation

Symptom: all consumers migrated, `ADOBE_BOT_NPM_TOKEN` was rotated out,
and a policy decision is made to revert to token-based publishing (very
unlikely, but planning for it makes the OIDC adoption safer to commit to).

Procedure:

1. Mint a new `ADOBE_BOT_NPM_TOKEN` on npmjs.com as `adobe-bot`. Push
   it back into the org secret store.
2. For each consumer: revert their `npm-oidc-enabled: true` → `false`.
3. Optionally: revoke npm trust bindings via `npm trust revoke <pkg> --id <trust-id>`
   for cleanliness (not required — they're inert under token auth).

The reusable workflow's conditional logic keeps both paths viable
**until Phase 4** (token decommissioning). The dual-path window is
intentionally finite — see the Phase 4 forcing function below for the
commitment and the laggard policy that ensures the legacy `NPM_TOKEN`
env injection is removed rather than carried as permanent tech debt.
Until Phase 4 lands, every consumer can switch back and forth via the
input.

## Failure modes when `npm-oidc-enabled: true`

Reference: `adobe/spacecat-shared/docs/RELEASE-RUNBOOK.md` documents the
analogue failure modes for a directly-OIDC repo. The shapes below are
adapted for the reusable-workflow context where there are 14 consumers.

### FM-A: OIDC token exchange returns 404 (trust binding missing)

Symptom in the run log:
```
[@semantic-release/npm] › Verifying OIDC context for publishing from GitHub Actions
[@semantic-release/npm] › OIDC token exchange with the npm registry failed: 404 OIDC token exchange error - package not found
[@semantic-release/npm] › Verify authentication for registry https://registry.npmjs.org/
npm error 401 Unauthorized - GET https://registry.npmjs.org/-/whoami
```

Cause: the consumer enabled `npm-oidc-enabled: true` before registering
the npm trust binding on npmjs.com (or the binding's `workflow_ref` /
`environment` / `repository` doesn't match the actual workflow run claims).

The 401 fallback fails because OIDC mode leaves `NPM_TOKEN` UNSET (the
legacy-mode injection step is gated on `!inputs.npm-oidc-enabled`, so it
is skipped). The variable is genuinely absent — not an empty string — to
remove any chance that `@semantic-release/npm` interprets `""` as
"authenticate with the empty token" and bypasses the OIDC fallback. The
fail-fast behavior is the intent: a missing trust binding surfaces
immediately rather than silently regressing to token publishing.

Recovery:

1. **Fastest:** flip `npm-oidc-enabled: false` in the caller workflow,
   merge, wait for the next release. Then fix the binding in a follow-up.
2. **Proper:** as `adobe-bot`, run `npm trust github <pkg> --repository
   <consumer-repo> --file <caller-workflow>.yaml --environment <env> --yes`
   for each affected package. Re-run the failed workflow.

### FM-B: Sigstore unreachable mid-publish

Symptom: `NPM_CONFIG_PROVENANCE: 'true'` is set, sigstore (status.sigstore.dev)
is having an outage, the release step fails with a sigstore-related error.

Cause: provenance attestations require a live signature from sigstore.
When sigstore is down, no publish succeeds.

Recovery (preferred, single flag flip):

1. **Primary:** flip `npm-oidc-enabled: true` → `false` in the consumer's
   caller workflow and merge. Token-based publishing has no sigstore
   dependency. When sigstore is back, flip the flag back to `true`.
2. **Alternative (if and only if the legacy token has been decommissioned
   in this consumer):** open a PR against `adobe/mysticat-ci` to add a
   `provenance-enabled` input that gates `NPM_CONFIG_PROVENANCE`. Today
   no such input exists; do NOT attempt to set `NPM_CONFIG_PROVENANCE` via
   `with:` — the reusable workflow does not accept it and the override
   would silently no-op.

Watch https://status.sigstore.dev/ for incidents. If FM-B becomes
recurring rather than rare, prioritize landing the `provenance-enabled`
input (tracked as a follow-up) so the flip-back is per-incident rather
than per-consumer.

### FM-C: Environment approval gate stalls

Symptom: release job sits at "Waiting for approval" indefinitely.

Cause: the consumer's `npm-publish` (or `prod`) environment is configured
with required reviewers, and no approver is online.

Recovery: as a repo admin on the consumer repo, either approve via the
Actions UI, OR temporarily drop the reviewer rule. **Important:** the
`PUT environments` API replaces the entire `deployment_branch_policy`
object, so you must re-state the `main` allowance — omitting it leaves
the env accepting publishes from any branch:

```bash
cat <<'JSON' | gh api -X PUT repos/adobe/<consumer-repo>/environments/npm-publish --input -
{
  "wait_timer": 0,
  "prevent_self_review": true,
  "reviewers": [],
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  }
}
JSON

# Then re-add 'main' to the custom branch list (the PUT above clears it):
gh api -X POST "repos/adobe/<consumer-repo>/environments/npm-publish/deployment-branch-policies" \
  -f name=main
```

The pending deployment auto-advances. Re-add reviewers afterwards if the
policy still applies. Verify the post-recovery state with:

```bash
gh api "repos/adobe/<consumer-repo>/environments/npm-publish/deployment-branch-policies" \
  --jq '.branch_policies[].name'
# Expect: main
```

### FM-D: Workflow / environment renamed

Symptom: first release after a rename fails with `OIDC trust binding mismatch`.

Cause: npm trust bindings reference `{repo, workflow_ref filename, environment}`.
Renaming the caller workflow file, the consumer repo, or the env breaks
all bindings registered against the old name.

Recovery:

1. Re-register each binding with the new name via the same `npm trust
   github` invocation pattern, updating whichever field changed.
2. Optionally revoke the stale bindings: `npm trust list <pkg>` to find
   the old binding's id, then `npm trust revoke <pkg> --id <id>`.

## Self-review (audit of backward compatibility)

Re-derived after the v1-of-PR-14 round-1 review caught a critical
publish-path defect (the `${{ inputs.npm-oidc-enabled && '' || ... }}`
ternary returned the real token when OIDC was on). The current code
shape uses a gated-step pattern for `NPM_TOKEN` and an explicit OIDC
preflight, so the publish-path env table looks different from the
original PR description's claim. Default-false code paths still produce
behavior identical to the pre-PR workflow.

| Element | Pre-PR | Post-PR (input=false) | Post-PR (input=true) |
|---|---|---|---|
| `NPM_TOKEN` on dry-run env | injected from secret | injected via `$GITHUB_ENV` from secret by gated step | **UNSET** (gated step skipped — variable absent, not `''`) |
| `SR_NO_NPM_AUTH` on dry-run env | unset | unset (`''`) | `'true'` |
| `NPM_TOKEN` on release env | injected from secret | injected via `$GITHUB_ENV` from secret by gated step | **UNSET** (gated step skipped — variable absent, not `''`) |
| `NPM_CONFIG_PROVENANCE` on release env | unset | unset (`''`) | `'true'` |
| `environment:` claim | `'prod'` if `vpc-enabled`, else none | identical | `'prod'` if `vpc-enabled`, else `'npm-publish'` |
| OIDC preflight step | n/a | not run (`if:` false) | runs (env policy + npm floor) |
| "Update NPM" step | n/a | not run (`if:` false) | runs (`npm@11.13.0`, retry + version assertion) |
| "Verify OIDC publish identity" step | n/a | not run (`if:` false) | runs (`_npmUser` must be `"GitHub Actions"`) |
| `id-token: write` permission | already present (for AWS OIDC) | unchanged | unchanged |

Notes:

- **UNSET vs `''` matters.** OIDC mode leaves `NPM_TOKEN` genuinely
  absent from the environment, not empty-string. There is evidence in
  npm's recent releases that an empty `NPM_TOKEN` can suppress OIDC
  fallback (npm tries the empty token rather than falling back to OIDC),
  so the gated-step pattern is correct under both readings and the
  ternary form is not.
- `process.env.SR_NO_NPM_AUTH === 'true'` (strict equality) returns
  false for both `''` and `undefined`, so the consumer's `.releaserc.cjs`
  guard behaves identically.
- `process.env.NPM_CONFIG_PROVENANCE` set to `''` is read by npm as
  "config not set," same as unset.
- The structural `NPM_TOKEN`-shape and the matrix render assertions are
  enforced by `.github/workflows/test-publish-path-render.yaml`, which
  fails CI on this repo if a regression to the ternary form (or any
  inline `NPM_TOKEN:` on the Semantic Release env block) is introduced.

No observable behavior change for consumers who don't flip the input.

## Order of operations checklist

Per consumer:

- [ ] PR: add `SR_NO_NPM_AUTH === 'true'` guard to `.releaserc.cjs`.
- [ ] PR: bump `engines.npm` in `package.json`.
- [ ] PR: pin caller workflow to `adobe/mysticat-ci/...@v3` (do NOT flip
      `npm-oidc-enabled: true` yet).
- [ ] Repo settings: create/configure `npm-publish` (or `prod` if VPC) env.
- [ ] Repo settings: tighten branch protection on `main`.
- [ ] As `adobe-bot`: register npm trust bindings for each package.
- [ ] PR: flip `npm-oidc-enabled: true` in the caller workflow. (This is
      the cutover commit; watch the first release on `main`.)
- [ ] Verify provenance + publisher on at least one published package.
- [ ] After 2 successful releases: rotate `ADOBE_BOT_NPM_TOKEN` out.

## Release + rollout strategy

This section is the **owner-side plan** for cutting `v3.0.0` of
`adobe/mysticat-ci` and rolling it out across the 14 consumer service
repos in a controlled, observable, reversible sequence.

### Phase 0 — Cut `v3.0.0`

When PR #14 merges:

1. Tag the merge commit `v3.0.0`. The repo's existing `release.yaml`
   workflow (the major-version-tag updater) will move the floating `v3`
   tag to point at it.
2. Optionally publish a GitHub Release with the PR's "Rollback" and
   "Failure modes" sections inlined as release notes (reduces friction
   for consumers reading the changelog).
3. **Do not nudge any consumer to upgrade.** Phase 1 (canary) starts
   only after `v3` is tagged and observable on the GitHub UI.

Pre-cut checks:

- [ ] CI on this PR is green.
- [ ] At least one of: solaris007 / aniham / ramboz / iuliag / akshaymagapu
      (or another mysticat-ci maintainer) has approved.
- [ ] Spot-read the diff one more time — particularly the
      `environment: ${{ (inputs.vpc-enabled && 'prod') || (inputs.npm-oidc-enabled && 'npm-publish') || '' }}`
      precedence and the dry-run + release token expressions, because
      a typo here breaks every consumer that opts in.

### Phase 1 — Canary (1 repo, ≥ 1 week observation)

Goal: prove the consumer-side recipe works end-to-end on a low-stakes
repo before propagating.

Canary selection criteria (pick ONE that satisfies all):

- Active enough to actually exercise OIDC ≥ 2 times in the observation
  window (≥ 1 release per week historically).
- Low blast radius: if its publish breaks, downstream pain is bounded
  to a small set of consumers.
- Not VPC-enabled (keeps the env path as `npm-publish`, not `prod`,
  which is the simpler path to validate first).
- Not in a code-freeze window.

Likely candidates from the 14 today, in rough order:

1. `spacecat-jobs-dispatcher` — small surface, regular releases.
2. `spacecat-task-processor` — similar profile.
3. `mysticat-projector-service` — adjacent codebase, isolated.

(If all candidates are VPC-enabled, pick the lowest-volume one and
verify the `prod` env binding path explicitly during Phase 1.)

Execute steps 1-7 of the "Order of operations checklist" on the canary.

Success criteria (all must hold for ≥ 1 week before Phase 2):

- ≥ 2 OIDC releases land successfully on `main`.
- Every published version shows `_npmUser: "GitHub Actions"` (not
  `adobe-admin`) on `npm view @adobe/<pkg> _npmUser`.
- Every published version carries a provenance attestation:
  `npm view @adobe/<pkg> dist.attestations` returns non-empty.
- The SLSA attestation's `workflow.path` field points at the canary's
  **caller** workflow (e.g. `adobe/spacecat-jobs-dispatcher/.github/workflows/main.yaml`),
  **not** `adobe/mysticat-ci/.github/workflows/service-ci.yaml`. If it
  points at the latter, the trust binding was registered against
  `job_workflow_ref` instead of `workflow_ref` — fail-stop and re-register
  before continuing.
- No FM-A / FM-B / FM-C / FM-D incidents (see "Failure modes" section).
- Dry-run on PRs still passes (no @semantic-release/npm errors).

Rollback trigger during Phase 1: any of:

- An OIDC release fails for a reason other than a transient sigstore
  outage (FM-B).
- The provenance attestation's `workflow.path` is wrong.
- Adobe org-wide sigstore outage that exceeds 4 hours.

Rollback procedure: flip `npm-oidc-enabled: true` → `false` in the
canary's caller workflow, ship a follow-up PR fixing whatever broke,
then re-enter Phase 1.

### Phase 2 — Pilot batch (3 repos, ≥ 1 week observation)

After Phase 1 success criteria hold for the canary, expand to a small
batch with diversity in profile:

- 1 more non-VPC service (regular publish flow).
- 1 VPC-enabled service (validates the `--environment prod` binding path).
- 1 service that publishes more than one package (validates the
  per-package binding registration loop).

Each pilot consumer runs the consumer-side checklist independently.
They can run in parallel — no inter-consumer dependency in this
migration (each consumer publishes its own packages).

Success criteria: identical to Phase 1, applied per pilot consumer.

Rollback trigger: if the canary or any pilot has a regression that
isn't caught by the existing failure-mode docs, **add a new failure
mode to the doc before continuing to Phase 3**. The runbook should be
kept honest as the operational source of truth for the rollout, even
though the enforced contract lives in the workflow and the npm trust
binding (not the prose).

### Phase 3 — Bulk rollout (remaining 10 repos)

Once Phases 1-2 have produced 4 successful migrations with no novel
failure modes, the remaining consumers can migrate in parallel. Each
repo's owner runs the consumer-side checklist on their own schedule.

Coordination needed (lightweight):

- A tracking issue in `adobe/mysticat-ci` listing all 14 consumers with
  a checkbox per repo. Each owner ticks their box when their consumer
  has ≥ 2 OIDC releases. (Recommended PR-spawned: open this issue right
  after `v3.0.0` is tagged.)
- A shared status doc / Slack channel for asking questions during
  the rollout — the migration doc is the first answer, but edge cases
  will surface.

Suggested order within the bulk batch (not load-bearing, just reduces
risk):

1. Repos with current active development (catches issues fast).
2. VPC consumers grouped together (so the `--environment prod` recipe
   variant is exercised consistently).
3. Lowest-volume / least-active repos last (their next release may be
   weeks out; rolling them last avoids leaving stragglers).

Success criteria: every consumer has ≥ 2 OIDC release cycles. Track
via the tracking issue.

### Phase 4 — Token decommissioning

When every consumer has crossed the ≥ 2-cycle threshold, **or** when the
Phase 4 deadline below is reached — whichever comes first:

1. Open a PR in `adobe/mysticat-ci` removing the legacy `NPM_TOKEN` env
   injection from `service-ci.yaml` (the gated "Configure NPM_TOKEN
   (legacy mode only)" steps for both dry-run and release, plus any
   conditional branches that still reference `secrets.ADOBE_BOT_NPM_TOKEN`).
   At this point the input becomes "always-on OIDC" or a no-op flag.
2. Delete `ADOBE_BOT_NPM_TOKEN` from the `adobe` org secrets.
3. As `adobe-bot`, revoke the npm-side token via `npm token revoke <id>`.
4. Cut `v4.0.0` of `mysticat-ci` to reflect the major contract change
   (no more token fallback path) and to give consumers a discrete signal
   to pin against.

#### Phase 4 forcing function

Deadline-free voluntary migrations across many owners reliably stall
with a long tail; left unchecked, that tail blocks token deletion
forever and leaves the org carrying both publish paths plus a long-lived
secret. To prevent that, Phase 4 has a hard target:

- **Target date: `v3.0.0` tag date + 3 months.** The expectation is that
  every consumer is on OIDC by then. Tracked on the Phase 3 issue with a
  visible target date in the issue body.
- **Laggard policy:** at target date + 30 days, the mysticat-ci owner
  opens a follow-up PR that flips the default of `npm-oidc-enabled` from
  `false` to `true` (cut as `v3.x.0`). Any consumer still pinning `@v3`
  who has not migrated their server-side setup will get a fail-fast OIDC
  preflight error on the next release rather than a silent regression —
  that is the intended forcing function, because the failure surfaces
  during *their* next release, not during a coordinated cutover window.
- **Phase 4 lands at target date + 60 days regardless,** unless an
  explicit org-level exception is filed by an unmigrated consumer's
  owner. The exception process is a tracking-issue comment naming the
  blocker and a new target date.

Until those dates: each consumer's "≥ 2 successful cycles" is the
preferred gating signal, and the Phase 3 tracking issue is the source of
truth. The deadlines are the backstop.

### Communication template

For each consumer's owner, when their repo is up next:

> Subject: Migrate `<repo>` to npm OIDC via mysticat-ci@v3
>
> `adobe/mysticat-ci` v3.0.0 is out, with opt-in `npm-oidc-enabled`
> support. Migration recipe + rollback procedures are in
> `adobe/mysticat-ci/docs/npm-oidc-migration.md`.
>
> Your repo is up. Steps in order:
>   1. PR: add SR_NO_NPM_AUTH guard to `.releaserc.cjs`, bump engines.npm,
>      pin caller workflow to `@v3` (keep flag false).
>   2. Repo settings: create `npm-publish` env (`main`-only branch policy,
>      `can_admins_bypass: false`), tighten branch protection.
>   3. Coordinate with whoever has `adobe-bot` npm credentials to register
>      trust bindings for your packages (one command per package).
>   4. PR: flip `npm-oidc-enabled: true`. Watch the first release on main.
>   5. After 2 successful releases, tick your box on the tracking issue.
>
> Rollback is one flag flip. Failure modes are documented. Ping me if
> anything in the doc is ambiguous — this doc is the operational runbook
> and rollout plan; the enforced contract is the workflow expressions,
> the npm trust binding, and the env's branch policy.

### What can go wrong with the rollout itself (not consumer-specific)

- **`v3` tag not pinned by consumers**: if a consumer pins to `@main`
  or `@latest` (anti-pattern), they'd inherit `v3.0.0`'s behavior
  immediately. Default-false flag means no observable change unless
  they also opt in, so this is safe; still, repo-survey for
  `mysticat-ci@main` pins is worth doing before tagging `v3`.
- **Org-wide sigstore outage during rollout**: don't start a new
  consumer's Phase 1 if sigstore is degraded. Defer until status is
  green.
- **`adobe-bot` npm credentials unavailable**: only one person typically
  has these. Lock in a second operator for the rollout window so the
  bus factor isn't 1.
- **`ADOBE_BOT_NPM_TOKEN` rotation event mid-rollout**: if the token
  rotates while half of consumers are on OIDC and half on token, the
  not-yet-migrated half breaks. Coordinate with whoever owns the token
  rotation cadence — ideally pause rotation for the rollout window, or
  prioritize migrating the token-dependent consumers first.

## Security note: binding to reusable workflows

`mysticat-ci/service-ci.yaml` is called via `workflow_call` from each
consumer's caller workflow. When the reusable workflow runs, GitHub mints
an OIDC token with two relevant claims:

- `workflow_ref` — the **caller's** workflow path
  (e.g. `adobe/spacecat-api-service/.github/workflows/main.yaml@refs/heads/main`)
- `job_workflow_ref` — the **reusable** workflow's path
  (e.g. `adobe/mysticat-ci/.github/workflows/service-ci.yaml@refs/tags/v3.0.0`)

npm Trusted Publishers authorizes against the caller's `workflow_ref`,
not `job_workflow_ref`. The npm docs make this explicit: when a workflow
uses `workflow_call`, *"validation checks the calling workflow's name
instead of the workflow that actually contains the publish command"*.
Therefore the trust binding **must** be registered against the caller
repo + caller filename, which is exactly what
`npm trust github --repository <consumer-repo> --file <caller-filename>`
does.

What if you mis-register against `adobe/mysticat-ci/service-ci.yaml`?
The binding will fail to match at runtime — the OIDC token's `repository`
claim is the caller's repo and its `workflow_ref` is the caller's file,
neither of which references `mysticat-ci`. The publish step gets a 404
and the release fails loud (see FM-A). This is **fail-closed**: a
mis-registered binding cannot enable cross-consumer publishing, because
the runtime claims never reference the reusable workflow's repo. The
recipe still puts the caller-side binding form front and center because
the caller-side binding is the only form that ever succeeds — but the
failure mode of getting it wrong is a loud release-time error, not a
silent cross-consumer hijack.

(Earlier revisions of this doc framed the misregistration risk as
fail-open, citing npm "checking both claims." That was inverted: npm
checks the caller's `workflow_ref`, full stop. The actionable instruction
— bind to caller repo + caller filename — was correct either way; the
revised wording above describes the actual threat model.)
