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

- Dry-run runs with `SR_NO_NPM_AUTH=true` and no `NPM_TOKEN`.
- Release runs with `NPM_CONFIG_PROVENANCE=true`, no `NPM_TOKEN`, and
  `environment: npm-publish` (or `prod` if `vpc-enabled: true` — see
  environment selection below).
- An "Update NPM" step installs `npm@11.13.0` to satisfy the OIDC floor
  (`npm >= 11.5.1`).

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
- **Deployment branch policy** → selected branches → add `main`.
- Required reviewers: optional. See "Reviewer policy" below.

VPC consumers should add `main` to their existing `prod` environment's
branch policy (or accept that `prod` already has it) — the OIDC binding
will use `--environment prod` instead of `npm-publish`.

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

To add a reviewer gate later:

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
```

`prevent_self_review` MUST be `true` whenever `reviewers` is non-empty.

## Rollback

The contract is designed so that **every backwards transition is a single
flag flip**. `ADOBE_BOT_NPM_TOKEN` should be retained as an org secret for
at least 2 successful OIDC releases per consumer before rotation.

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
   | `NPM_TOKEN` env on dry-run + release | `''` (empty) | `secrets.ADOBE_BOT_NPM_TOKEN` |
   | `SR_NO_NPM_AUTH` env on dry-run | `'true'` | `''` (unset) |
   | `NPM_CONFIG_PROVENANCE` env on release | `'true'` | `''` (unset) |
   | `environment:` claim | `npm-publish` (or `prod` if vpc-enabled) | `prod` if vpc-enabled, else none |
   | "Update NPM" step | runs (`npm@11.13.0`) | skipped |

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
indefinitely. Removal of the legacy path (the `NPM_TOKEN` env injection
in `service-ci.yaml`) is a separate decision; until then, every consumer
can switch back and forth via the input.

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

The 401 fallback fails because OIDC mode sets `NPM_TOKEN: ''`. This is
intentional — failing fast surfaces the missing trust binding rather
than silently falling back to an old token.

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

Recovery (temporary, requires a hotfix PR on the consumer repo):

1. Add an explicit override at the caller workflow level. The simplest
   form is to inject `NPM_CONFIG_PROVENANCE: 'false'` via a `with:`
   workaround. For now, this is not parameterized through the reusable
   workflow — file a PR against mysticat-ci to add a `provenance-enabled`
   input if this becomes a recurring need.
2. Alternative: flip `npm-oidc-enabled: false` for the duration of the
   sigstore outage. Token-based publishing has no sigstore dependency.

Watch https://status.sigstore.dev/ for incidents.

### FM-C: Environment approval gate stalls

Symptom: release job sits at "Waiting for approval" indefinitely.

Cause: the consumer's `npm-publish` (or `prod`) environment is configured
with required reviewers, and no approver is online.

Recovery: as a repo admin on the consumer repo, either approve via the
Actions UI, OR temporarily drop the reviewer rule with:

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
```

The pending deployment auto-advances. Re-add reviewers afterwards if the
policy still applies.

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

Audited as part of preparing this PR. Default-false code paths produce
behavior identical to the pre-PR workflow:

| Element | Pre-PR | Post-PR (input=false) | Post-PR (input=true) |
|---|---|---|---|
| `NPM_TOKEN` on dry-run env | secret value | secret value | `''` |
| `SR_NO_NPM_AUTH` on dry-run env | unset | unset (`''` evaluates as unset for GH) | `'true'` |
| `NPM_TOKEN` on release env | secret value | secret value | `''` |
| `NPM_CONFIG_PROVENANCE` on release env | unset | unset (`''`) | `'true'` |
| `environment:` claim | `'prod'` if `vpc-enabled`, else none | identical | `'prod'` if `vpc-enabled`, else `'npm-publish'` |
| "Update NPM" step | n/a | not run (`if:` evaluates false) | runs (`npm@11.13.0`) |
| `id-token: write` permission | already present (for AWS OIDC) | unchanged | unchanged |

Notes on the `''` vs unset distinction:

- GitHub Actions does set the env var to an empty string when an
  expression evaluates to `''`. This is a minor difference from "not
  set at all" in legacy mode.
- `@semantic-release/npm` checks `process.env.NPM_TOKEN` truthiness;
  `''` is falsy, so it behaves identically to unset.
- `process.env.SR_NO_NPM_AUTH === 'true'` (strict equality) returns
  false for both `''` and `undefined`, so the consumer's `.releaserc.cjs`
  guard behaves identically.
- `process.env.NPM_CONFIG_PROVENANCE` set to `''` is read by npm as
  "config not set," same as unset.

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
mode to the doc before continuing to Phase 3**. The doc is part of the
forward-compatibility contract for the rollout.

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

Only when every consumer has crossed the ≥ 2-cycle threshold:

1. Open a PR in `adobe/mysticat-ci` removing the legacy `NPM_TOKEN` env
   injection from `service-ci.yaml` (the conditional branches that select
   `secrets.ADOBE_BOT_NPM_TOKEN` when `npm-oidc-enabled: false`). At this
   point the input becomes "always-on OIDC" or a no-op flag.
2. Delete `ADOBE_BOT_NPM_TOKEN` from the `adobe` org secrets.
3. As `adobe-bot`, revoke the npm-side token via `npm token revoke <id>`.
4. (Optional) cut `v4.0.0` of `mysticat-ci` to reflect the major
   contract change (no more token fallback path).

Decommissioning is *not* a rush job. Each consumer's "≥ 2 successful
cycles" is the gating signal, not a calendar date. Tracking issue from
Phase 3 is the source of truth.

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
> anything in the doc is ambiguous — the doc is part of the contract.

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

- `workflow_ref` — the caller's workflow path
  (e.g. `adobe/spacecat-api-service/.github/workflows/main.yaml@refs/heads/main`)
- `job_workflow_ref` — the reusable workflow's path
  (e.g. `adobe/mysticat-ci/.github/workflows/service-ci.yaml@refs/tags/v3.0.0`)

npm Trusted Publishers checks both claims against the registered binding.
**Always bind packages to `workflow_ref` (caller), not `job_workflow_ref`
(reusable).** A binding pointing at `adobe/mysticat-ci/...` would let any
consumer that calls the reusable workflow publish your package — that is
not a security boundary worth keeping.

The npm CLI's `npm trust github` command binds against the caller's
`workflow_ref` when you pass `--repository <consumer-repo> --file <caller-filename>`.
Binding against the reusable workflow requires a different command/flow
and should not be used for this migration.
