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
