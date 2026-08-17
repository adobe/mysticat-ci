#!/usr/bin/env bash
# Append a ServiceNow-CMR-compatible change-management attributes block to a
# published GitHub release. Idempotent: a release that already carries the block
# is left untouched. Decoration only — no ServiceNow API calls.
#
# Usage: release-cm.sh <tag>
# Env:
#   REPO      owner/repo            (default: $GITHUB_REPOSITORY)
#   GH_TOKEN  token, contents:write (gh reads this)
#   SNOW_YML  path to .snow.yml     (default: .snow.yml)
#   DRY_RUN   when non-empty, print the block instead of editing the release
set -euo pipefail

TAG="${1:?usage: release-cm.sh <tag>}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
SNOW_YML="${SNOW_YML:-.snow.yml}"

# serviceIds from .snow.yml — inline-array form, e.g. `serviceIds: [572778, 572779]`
service_ids=""
if [ -f "$SNOW_YML" ]; then
  service_ids=$(grep -E "^[[:space:]]*serviceIds:" "$SNOW_YML" \
    | sed -E "s/^[^[]*\[([^]]*)\].*/\1/" | tr -d " ")
fi
[ -n "$service_ids" ] || echo "WARN: no serviceIds found in $SNOW_YML" >&2

# Current release body + idempotency guard
body=$(gh release view "$TAG" -R "$REPO" --json body -q .body 2>/dev/null || true)
if printf "%s" "$body" | grep -q "cm-attributes: v1"; then
  echo "release $TAG already decorated — nothing to do"
  exit 0
fi

# Previous release tag (for the backout plan): the entry after $TAG in the date-desc list
prev=$(gh release list -R "$REPO" -L 100 --json tagName -q ".[].tagName" \
  | awk -v t="$TAG" 'found{print; exit} $0==t{found=1}')

repo_name="${REPO##*/}"
block=$(cat <<EOF

## Change Management

\`\`\`yaml
cm-attributes: v1
serviceIds: [${service_ids}]
changeType: standard
risk: low
environment: production
shortDescription: "${repo_name} ${TAG}"
implementationPlan: "semantic-release deploy on merge to main"
backoutPlan: "redeploy previous release ${prev:-unknown}"
closeCode: successful
correlationId: ${TAG}
cmr: null
\`\`\`
EOF
)

if [ -n "${DRY_RUN:-}" ]; then
  echo "=== DRY RUN: would append to ${REPO} release ${TAG} ==="
  printf "%s\n" "$block"
  exit 0
fi

gh release edit "$TAG" -R "$REPO" --notes "${body}${block}"
echo "decorated ${REPO} release ${TAG}"
