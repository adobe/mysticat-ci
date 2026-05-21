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

`ADOBE_BOT_NPM_TOKEN` should be retained as an org secret for at least 2
successful OIDC releases per consumer. To roll back:

1. Set `npm-oidc-enabled: false` in the caller workflow.
2. The next release uses the legacy `NPM_TOKEN` path again (env, dry-run
   token, no provenance) — no code changes elsewhere needed because the
   workflow's conditionals handle both paths.
3. The `.releaserc.cjs` `SR_NO_NPM_AUTH` guard is a no-op when the env var
   is unset, so it stays in place harmlessly across rollback.

The `npm trust` bindings on npmjs.com are non-blocking for token-based
publish, so no npm-side cleanup is required during rollback.

After 2 successful OIDC release cycles, remove `ADOBE_BOT_NPM_TOKEN` from
the org secrets (separately, revoke the npm-side token).

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
