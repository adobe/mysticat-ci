# VPC configuration for Lambda services

This document describes how consumer repos opt in to declarative VPC attachment via `service-ci.yaml` and how to roll back if something goes wrong.

## What this replaces

Previously, Lambda VPC attachment for SpaceCat / Mysticat services was set by hand in the AWS console. The declarative path uses helix-deploy 13.4+ CLI flags (`--aws-vpc-subnet-ids`, `--aws-vpc-security-group-ids`) driven from `package.json` `hlx`, with per-environment GitHub Environment secrets feeding the values in.

## Consumer migration (four steps)

Do all four in a single PR so the config, the code, and the deploy are coherent.

### 1. Create GitHub Environments

Create three environments in the consumer repo — note that **feature-branch deploys use `dev-branches`, not `dev`**:

| Environment     | Used by              | Triggered on                        |
|-----------------|----------------------|-------------------------------------|
| `dev-branches`  | `branch-deploy` job  | push to any non-main branch         |
| `stage`         | `deploy-stage` job   | push to `main`                      |
| `prod`          | `semantic-release`   | push to `main` (semantic-release)   |

Why `dev-branches` and not `dev`: feature-branch deploys need to stay cadence-friendly. Giving them their own environment name keeps them decoupled from any future protection rules teams might want to apply to `dev` for other pipelines.

Defaults (no protection rules) are fine to start — see "Environment protection" below for what to add after the pilot.

### 2. Populate environment-scoped secrets

Per environment (`dev-branches`, `stage`, `prod`), add these three secrets (values come from `spacecat-infrastructure` Terraform outputs in the matching AWS account; `dev-branches` uses the **dev** account's values):

| Secret                   | Source                                                  | Required when                |
|--------------------------|---------------------------------------------------------|------------------------------|
| `VPC_SUBNET_1`           | `module.spacecat_vpc.private_subnet_ids[0]`             | `vpc-enabled: true`          |
| `VPC_SUBNET_2`           | `module.spacecat_vpc.private_subnet_ids[1]`             | `vpc-enabled: true`          |
| `VPC_SG_ID`              | `module.spacecat_vpc.lambda_security_group_id`          | `vpc-enabled: true`          |
| `MAC_GIVER_CALLER_SG_ID` | `module.spacecat_vpc.mac_giver_caller_security_group_id`| `mac-giver-caller: true`     |

### 3. Opt in on the workflow call

Pin to `@v2`, set `vpc-enabled: true`, confirm `secrets: inherit`:

```yaml
jobs:
  ci:
    uses: adobe/mysticat-ci/.github/workflows/service-ci.yaml@v2
    with:
      service-name: <service>
      vpc-enabled: true
    secrets: inherit
```

Optional input: `lambda-function-name` overrides the default function-name convention (`spacecat-services--<service-name>`) used by the post-deploy verify step. Set this when the deployed Lambda name does not match the convention.

Optional input: `mac-giver-caller: true` attaches the mac-giver caller security group in addition to the shared lambda SG. Set this only on Lambdas that are authorised to call mac-giver (the IMS auth Lambdas). Requires `vpc-enabled: true`, requires the `MAC_GIVER_CALLER_SG_ID` secret to be populated in each environment the feature is active in, and requires the consumer's `package.json` to include `${env.MAC_GIVER_CALLER_SG_ID}` in `hlx.awsVpcSecurityGroupIds`:

```yaml
jobs:
  ci:
    uses: adobe/mysticat-ci/.github/workflows/service-ci.yaml@v2
    with:
      service-name: auth-service
      vpc-enabled: true
      mac-giver-caller: true
    secrets: inherit
```

```json
"hlx": {
  "awsVpcSubnetIds": ["${env.VPC_SUBNET_1}", "${env.VPC_SUBNET_2}"],
  "awsVpcSecurityGroupIds": ["${env.VPC_SG_ID}", "${env.MAC_GIVER_CALLER_SG_ID}"]
}
```

The post-deploy verify step additionally asserts that the deployed Lambda's `VpcConfig.SecurityGroupIds` contains `MAC_GIVER_CALLER_SG_ID`.

### Rolling mac-giver-caller out per environment

`mac-giver-caller-environments` (CSV, default empty = all envs) restricts the feature to a specific list of GitHub Environments. Use this when the `MAC_GIVER_CALLER_SG_ID` secret is staged into one environment at a time:

```yaml
jobs:
  ci:
    uses: adobe/mysticat-ci/.github/workflows/service-ci.yaml@v3
    with:
      service-name: auth-service
      vpc-enabled: true
      mac-giver-caller: true
      mac-giver-caller-environments: "dev-branches"   # stage/prod no-op until added
    secrets: inherit
```

Environments not in the list:
- skip the `MAC_GIVER_CALLER_SG_ID` secret-required check
- jq-strip the `${env.MAC_GIVER_CALLER_SG_ID}` placeholder from `package.json` `hlx.awsVpcSecurityGroupIds` before helix-deploy runs (helix-deploy refuses to deploy when the post-substitution SG array contains an empty string)
- skip the post-deploy "is the caller SG attached?" assertion

Add an environment to the list (and populate its secret) when you're ready to roll mac-giver forward to it.

Consumers that do not need VPC attachment can stay on `@v1` indefinitely; `v2` does not deprecate `v1`, it just ships the opt-in behavior.

## Guardrails

The `VPC config sanity check` step runs before every deploy and enforces:

| `vpc-enabled` | `package.json` has `awsVpcSubnetIds` | Result |
|---|---|---|
| `true`        | yes                                   | proceeds (after checking secrets are populated) |
| `true`        | no                                    | fails — workflow opt-in without hlx fields would no-op |
| `false`       | yes                                   | fails — would silently detach VPC on deploy |
| `false`       | no                                    | proceeds (non-VPC deploy) |

Post-deploy, the `Verify Lambda VPC attachment` step waits for the AWS update to settle (`aws lambda wait function-updated`) and asserts that the applied `VpcConfig.SubnetIds` and `SecurityGroupIds` contain the expected IDs. A mismatch fails the job and surfaces the actual `VpcConfig` in the log.

### 4. Reference the env vars in `package.json` hlx

```json
"hlx": {
  "awsVpcSubnetIds": ["${env.VPC_SUBNET_1}", "${env.VPC_SUBNET_2}"],
  "awsVpcSecurityGroupIds": ["${env.VPC_SG_ID}"]
}
```

Then push. `branch-deploy` will run under `environment: dev-branches`, validate the three secrets are non-empty, deploy, and assert post-deploy that the Lambda's `VpcConfig` matches the expected subnets and SG.

## Default behavior for non-opted-in callers

`vpc-enabled` defaults to `false`. With the flag unset, deploy jobs run exactly as before: no `environment:`, no VPC validation, no VPC env vars, no post-deploy VPC assertion. Existing consumers are unaffected until they opt in explicitly.

## Environment protection (recommended after pilot soak)

The default environments are unprotected, which preserves dev cadence but means anyone with `write` on the repo can ship a feature branch to the dev AWS account. Once the pilot has soaked:

- **`dev-branches`**: leave unprotected. Feature-branch deploy cadence depends on it. Gate who can push feature branches via git-side branch protection, not env protection.
- **`stage`**: deployment-branch policy restricting to `main`.
- **`prod`**: deployment-branch policy restricting to `main`, plus a required-reviewer rule on the environment.

Do **not** move `AWS_ACCOUNT_ID_DEV / _STAGE / _PROD` into environment secrets. They live at the repo level and are intentionally repo-scoped; duplicating them into an environment would silently shadow the repo values and risk deploying to the wrong account.

## Rollback

If a consumer's Lambda ends up with a wrong or broken VPC attachment:

1. **Immediate**: clear `vpc-enabled: true` from the caller workflow (flip back to `false` or delete the input). The next deploy exports empty `VPC_*` env vars; helix-deploy interprets `awsVpcSubnetIds: ["", ""]` as "detach VPC." Confirm with `aws lambda get-function-configuration --function-name <func> --query VpcConfig`.
2. **If detach misbehaves**: attach VPC manually in the AWS console to a known-good config (or via `aws lambda update-function-configuration --vpc-config SubnetIds=...,SecurityGroupIds=...`), then re-deploy once fixed.
3. **If CI is stuck at the validate step**: either populate the missing secret or flip `vpc-enabled` back to `false`.

## Egress note

VPC-attached Lambdas lose default internet egress. Reachability for SSM, S3, DynamoDB, SQS, Secrets Manager, IMS, external HTTPS (GSC, Ahrefs, npm at runtime, etc.) depends on the per-account networking: NAT gateways (in public subnets, see `spacecat-infrastructure/modules/vpc/main.tf`) and/or VPC endpoints. Before enabling VPC for a new service, confirm that every outbound dependency it has at runtime is reachable from the private subnets in the target AWS account. For services with many external dependencies, prefer a canary deploy and short soak before promoting.
