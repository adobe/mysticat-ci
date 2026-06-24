# mysticat-ci

Centralized GitHub Actions workflows for Mysticat (SpaceCat) service repos.

## Usage

```yaml
jobs:
  ci:
    uses: adobe/mysticat-ci/.github/workflows/service-ci.yaml@v1
    with:
      service-name: my-service
    secrets: inherit
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `service-name` | yes | - | Service name for artifact naming (e.g., `jobs-dispatcher`) |
| `validate-pr-title` | no | `false` | Run semantic PR title validation |
| `docs-lint` | no | `false` | Run `docs:lint` and `docs:build` in build step |
| `bundle-build` | no | `false` | Run `npm run build` (helix-deploy `--test-bundle`) in build step as a Lambda bundle smoke check. See [docs/bundle-build-gate.md](docs/bundle-build-gate.md). |
| `it-postgres` | no | `false` | Run PostgreSQL (v3) integration tests after build (requires ECR access). |
| `vpc-enabled` | no | `false` | Opt in to declarative Lambda VPC attachment. Requires the `VPC_SUBNET_1/2` and `VPC_SG_ID` GitHub Environment secrets and matching `hlx.awsVpcSubnetIds`/`hlx.awsVpcSecurityGroupIds` in `package.json`. See [docs/vpc-config.md](docs/vpc-config.md). |
| `mac-giver-caller` | no | `false` | Additionally attach the mac-giver caller security group. Requires `vpc-enabled: true` and the `MAC_GIVER_CALLER_SG_ID` secret. Only set for Lambdas authorised to call mac-giver. See [docs/vpc-config.md](docs/vpc-config.md#optional-input-mac-giver-caller-true-attaches-the-mac-giver-caller-security-group-in-addition-to-the-shared-lambda-sg). |
| `mac-giver-caller-environments` | no | `""` | Comma-separated allowlist of GitHub Environments where `mac-giver-caller` is active (e.g. `"dev-branches"` or `"dev-branches,stage"`). Default empty = active in all envs. Valid values: `dev-branches`, `stage`, `prod`. |
| `lambda-function-name` | no | derived | Override the function-name convention used by the post-deploy VPC verification step. Defaults to `spacecat-services--<service-name>`. |
