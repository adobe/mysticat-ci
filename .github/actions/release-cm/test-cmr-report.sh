#!/usr/bin/env bash
# Tests for cmr-report.sh (builds the navigable md tree from a run's data yaml files).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/cmr-report.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; shift; printf '%s\n' "$*" | sed 's/^/      /'; fail=$((fail+1)); }
inrepo(){ grep -qF "$1" "$R/adobe__spacecat-api-service/repo.md"; }

R="$TMP/run"
mkdir -p "$R/adobe__spacecat-api-service/v1.754.0" "$R/adobe__spacecat-api-service/v1.755.0"
mkdir -p "$R/adobe-rnd__llmo-data-retrieval-service/release-2026-08-18"
printf 'repo: adobe/spacecat-api-service\nhost: github.com\n' > "$R/adobe__spacecat-api-service/repo.yaml"
printf 'repo: adobe-rnd/llmo-data-retrieval-service\nhost: git.corp.adobe.com\n' > "$R/adobe-rnd__llmo-data-retrieval-service/repo.yaml"
printf 'tag: v1.754.0\nchangeType: standard\nimpact: degradation\nrisk: minor\nassessmentStatus: assessed\ncoverage: "2/2"\n' > "$R/adobe__spacecat-api-service/v1.754.0/release.yaml"
printf 'pr: 3073\ntitle: resolve Sites by full identity\nchangeType: standard\nimpact: degradation\nrisk: minor\nrationale: "reversible refactor"\n' > "$R/adobe__spacecat-api-service/v1.754.0/pr-3073.yaml"
printf 'pr: 3070\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nrationale: "additive"\n' > "$R/adobe__spacecat-api-service/v1.754.0/pr-3070.yaml"
printf 'tag: v1.755.0\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nassessmentStatus: assessed\ncoverage: "1/1"\n' > "$R/adobe__spacecat-api-service/v1.755.0/release.yaml"
printf 'pr: 3080\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nrationale: "bump"\n' > "$R/adobe__spacecat-api-service/v1.755.0/pr-3080.yaml"
printf 'tag: release-2026-08-18\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nassessmentStatus: assessed\ncoverage: "1/1"\n' > "$R/adobe-rnd__llmo-data-retrieval-service/release-2026-08-18/release.yaml"
printf 'pr: 42\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nrationale: "corp repo"\n' > "$R/adobe-rnd__llmo-data-retrieval-service/release-2026-08-18/pr-42.yaml"

OUT=$(bash "$SCRIPT" "$R" --mode suggest --since 2026-08-17 --title "CM audit — test" 2>&1); RC=$?

# T1 runs clean and reports scope
{ [ "$RC" -eq 0 ] && case "$OUT" in *"2 repos"*|*"2 repos, 3 releases, 4 PRs"*) true;; *) false;; esac; } \
  && ok "T1 exits 0 and reports scope" || no "T1" "$OUT (rc=$RC)"

# T2 full tree exists
{ [ -f "$R/README.md" ] \
  && [ -f "$R/adobe__spacecat-api-service/repo.md" ] \
  && [ -f "$R/adobe__spacecat-api-service/v1.754.0/release.md" ] \
  && [ -f "$R/adobe__spacecat-api-service/v1.754.0/pr-3073.md" ]; } \
  && ok "T2 nested md tree generated" || no "T2" "missing files"

# T3 README indexes repos (parent -> child link)
{ grep -qF '[adobe/spacecat-api-service](adobe__spacecat-api-service/repo.md)' "$R/README.md" \
  && grep -qF '(adobe-rnd__llmo-data-retrieval-service/repo.md)' "$R/README.md"; } \
  && ok "T3 README links to each repo.md" || no "T3" "$(cat "$R/README.md")"

# T4 repo.md links to each release.md and to GitHub
{ inrepo '(v1.754.0/release.md)' && inrepo '(v1.755.0/release.md)' \
  && inrepo 'https://github.com/adobe/spacecat-api-service'; } \
  && ok "T4 repo.md links releases + GitHub" || no "T4" "$(cat "$R/adobe__spacecat-api-service/repo.md")"

# T5 release.md carries the aggregate block and links each PR (page + GitHub)
rel="$R/adobe__spacecat-api-service/v1.754.0/release.md"
{ grep -qF 'assessedCoverage: "2/2"' "$rel" \
  && grep -qF '[PR #3073](pr-3073.md)' "$rel" \
  && grep -qF 'https://github.com/adobe/spacecat-api-service/pull/3073' "$rel" \
  && grep -qF 'https://github.com/adobe/spacecat-api-service/releases/tag/v1.754.0' "$rel"; } \
  && ok "T5 release.md aggregate + PR links" || no "T5" "$(cat "$rel")"

# T6 pr.md links up to release + GitHub PR, shows title + ratings
pr="$R/adobe__spacecat-api-service/v1.754.0/pr-3073.md"
{ grep -qF '> resolve Sites by full identity' "$pr" \
  && grep -qF 'https://github.com/adobe/spacecat-api-service/pull/3073' "$pr" \
  && grep -qF '[v1.754.0](./release.md)' "$pr" \
  && grep -qF '| standard | degradation | minor |' "$pr"; } \
  && ok "T6 pr.md detail + up-links" || no "T6" "$(cat "$pr")"

# T7 corp host routes GitHub links to git.corp.adobe.com
corp="$R/adobe-rnd__llmo-data-retrieval-service/release-2026-08-18/pr-42.md"
{ grep -qF 'https://git.corp.adobe.com/adobe-rnd/llmo-data-retrieval-service/pull/42' "$corp" \
  && ! grep -qF 'github.com/adobe-rnd' "$corp"; } \
  && ok "T7 corp host base url" || no "T7" "$(cat "$corp")"

# T8 no such run dir -> error, exit 1
OUT=$(bash "$SCRIPT" "$TMP/nope" 2>&1); RC=$?
{ [ "$RC" -eq 1 ] && case "$OUT" in *"no such run dir"*) true;; *) false;; esac; } \
  && ok "T8 missing run dir errors" || no "T8" "$OUT (rc=$RC)"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
