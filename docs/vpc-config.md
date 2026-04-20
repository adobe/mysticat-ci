# VPC configuration for Lambda services

This document describes how consumer repos opt in to declarative VPC attachment via `service-ci.yaml` and how to roll back if something goes wrong.

## What this replaces

Previously, Lambda VPC attachment for SpaceCat / Mysticat services was set by hand in the AWS console. The declarative path uses helix-deploy 13.4+ CLI flags (`--aws-vpc-subnet-ids`, `--aws-vpc-security-group-ids`) driven from `package.json` `hlx`, with per-environment GitHub Environment secrets feeding the values in.

## Consumer migration (four steps)

Do all four in a single PR so the config, the code, and the deploy are coherent.

### 1. Create GitHub Environments

Create `dev`, `stage`, `prod` in the consumer repo. Defaults (no protection rules) are fine to start — see "Environment protection" below for what to add after the pilot.

### 2. Populate environment-scoped secrets

Per environment, add these three secrets (values come from `spacecat-infrastructure` Terraform outputs in the matching AWS account):

| Secret        | Source                                                  |
|---------------|---------------------------------------------------------|
| `VPC_SUBNET_1`| `module.spacecat_vpc.private_subnet_ids[0]`             |
| `VPC_SUBNET_2`| `module.spacecat_vpc.private_subnet_ids[1]`             |
| `VPC_SG_ID`   | `module.spacecat_vpc.lambda_security_group_id`          |

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

Consumers that do not need VPC attachment can stay on `@v1` indefinitely; `v2` does not deprecate `v1`, it just ships the opt-in behavior.

### 4. Reference the env vars in `package.json` hlx

```json
"hlx": {
  "awsVpcSubnetIds": ["${env.VPC_SUBNET_1}", "${env.VPC_SUBNET_2}"],
  "awsVpcSecurityGroupIds": ["${env.VPC_SG_ID}"]
}
```

Then push. `branch-deploy` will run under `environment: dev`, validate the three secrets are non-empty, deploy, and assert post-deploy that the Lambda's `VpcConfig` matches the expected subnets and SG.

## Default behavior for non-opted-in callers

`vpc-enabled` defaults to `false`. With the flag unset, deploy jobs run exactly as before: no `environment:`, no VPC validation, no VPC env vars, no post-deploy VPC assertion. Existing consumers are unaffected until they opt in explicitly.

## Environment protection (recommended after pilot soak)

The default environments are unprotected, which preserves dev cadence but means anyone with `write` on the repo can ship a feature branch to the dev AWS account. Once the pilot has soaked:

- **`dev`**: optional deployment-branch policy or required reviewer for feature branches that deploy.
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
