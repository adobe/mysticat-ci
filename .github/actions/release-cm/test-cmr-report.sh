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

# T1 runs clean and reports the exact scope (all three counters, not just repos)
{ [ "$RC" -eq 0 ] && case "$OUT" in *"2 repos, 3 releases, 4 PRs"*) true;; *) false;; esac; } \
  && ok "T1 exits 0 and reports exact scope" || no "T1" "$OUT (rc=$RC)"

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

# T9 yget: keep a value that merely ends in a quote; strip an inline `# comment` on an enum
R9="$TMP/r9"; mkdir -p "$R9/o__r/v1"
printf 'repo: o/r\n' > "$R9/o__r/repo.yaml"
printf 'tag: v1\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nassessmentStatus: assessed\ncoverage: "1/1"\n' > "$R9/o__r/v1/release.yaml"
printf 'pr: 9\ntitle: rename flag to "v2"\nchangeType: standard   # standard | normal\nimpact: unnoticeable\nrisk: minor\nrationale: "ok"\n' > "$R9/o__r/v1/pr-9.yaml"
bash "$SCRIPT" "$R9" >/dev/null 2>&1
pr9="$R9/o__r/v1/pr-9.md"
{ grep -qF '> rename flag to "v2"' "$pr9" && grep -qF '| standard | unnoticeable | minor |' "$pr9"; } \
  && ok "T9 balanced-quote + inline-comment parsing" || no "T9" "$(cat "$pr9")"

# T10 PR link/URL come from the filename, not the internal pr: field (mismatch -> filename wins)
R10="$TMP/r10"; mkdir -p "$R10/o__r/v1"
printf 'repo: o/r\n' > "$R10/o__r/repo.yaml"
printf 'tag: v1\nassessmentStatus: assessed\n' > "$R10/o__r/v1/release.yaml"
printf 'pr: 5\nimpact: unnoticeable\nrisk: minor\n' > "$R10/o__r/v1/pr-6.yaml"
bash "$SCRIPT" "$R10" >/dev/null 2>&1
rel10="$R10/o__r/v1/release.md"
{ [ -f "$R10/o__r/v1/pr-6.md" ] && grep -qF '[PR #6](pr-6.md)' "$rel10" && grep -qF '/pull/6' "$rel10" && ! grep -qF 'pr-5.md' "$rel10"; } \
  && ok "T10 PR link uses filename, not internal pr:" || no "T10" "$(cat "$rel10")"

# T11 missing internal pr: field still links correctly by filename
R11="$TMP/r11"; mkdir -p "$R11/o__r/v1"
printf 'repo: o/r\n' > "$R11/o__r/repo.yaml"
printf 'tag: v1\nassessmentStatus: assessed\n' > "$R11/o__r/v1/release.yaml"
printf 'impact: unnoticeable\nrisk: minor\n' > "$R11/o__r/v1/pr-77.yaml"
bash "$SCRIPT" "$R11" >/dev/null 2>&1
{ [ -f "$R11/o__r/v1/pr-77.md" ] && grep -qF '[PR #77](pr-77.md)' "$R11/o__r/v1/release.md"; } \
  && ok "T11 missing pr: still links by filename" || no "T11" "$(cat "$R11/o__r/v1/release.md")"

# T12 accepts assessedCoverage as an alias for coverage
R12="$TMP/r12"; mkdir -p "$R12/o__r/v1"
printf 'repo: o/r\n' > "$R12/o__r/repo.yaml"
printf 'tag: v1\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nassessmentStatus: assessed\nassessedCoverage: "3/3"\n' > "$R12/o__r/v1/release.yaml"
printf 'impact: unnoticeable\nrisk: minor\n' > "$R12/o__r/v1/pr-1.yaml"
bash "$SCRIPT" "$R12" >/dev/null 2>&1
grep -qF 'assessedCoverage: "3/3"' "$R12/o__r/v1/release.md" \
  && ok "T12 accepts assessedCoverage alias" || no "T12" "$(cat "$R12/o__r/v1/release.md")"

# T13 URL-encodes a slash in the tag (release page link stays valid)
R13="$TMP/r13"; mkdir -p "$R13/o__r/hotfix__urgent"
printf 'repo: o/r\n' > "$R13/o__r/repo.yaml"
printf 'tag: hotfix/urgent\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nassessmentStatus: assessed\n' > "$R13/o__r/hotfix__urgent/release.yaml"
printf 'impact: unnoticeable\nrisk: minor\n' > "$R13/o__r/hotfix__urgent/pr-1.yaml"
bash "$SCRIPT" "$R13" >/dev/null 2>&1
rel13="$R13/o__r/hotfix__urgent/release.md"
{ grep -qF 'releases/tag/hotfix%2Furgent' "$rel13" && ! grep -qF 'releases/tag/hotfix/urgent' "$rel13"; } \
  && ok "T13 URL-encodes slash in tag" || no "T13" "$(cat "$rel13")"

# T14 a release.yaml nested below the flat layout is NOT silently dropped -> warns, exits 0
R14="$TMP/r14"; mkdir -p "$R14/o__r/a/b"
printf 'repo: o/r\n' > "$R14/o__r/repo.yaml"
printf 'tag: deep\nassessmentStatus: assessed\n' > "$R14/o__r/a/b/release.yaml"
OUT=$(bash "$SCRIPT" "$R14" 2>&1); RC=$?
{ [ "$RC" -eq 0 ] && case "$OUT" in *"::warning::"*"nested below"*) true;; *) false;; esac; } \
  && ok "T14 warns on release nested below flat layout" || no "T14" "$OUT (rc=$RC)"

# T15 URL-encodes a space (and slash) in a tag so the release link stays valid
R15="$TMP/r15"; mkdir -p "$R15/o__r/rel"
printf 'repo: o/r\n' > "$R15/o__r/repo.yaml"
printf 'tag: "team/release 2.0"\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nassessmentStatus: assessed\n' > "$R15/o__r/rel/release.yaml"
printf 'impact: unnoticeable\nrisk: minor\n' > "$R15/o__r/rel/pr-1.yaml"
bash "$SCRIPT" "$R15" >/dev/null 2>&1
rel15="$R15/o__r/rel/release.md"
grep -qF 'releases/tag/team%2Frelease%202.0' "$rel15" \
  && ok "T15 URL-encodes space + slash in tag" || no "T15" "$(cat "$rel15")"

# T16 a hostile tag ('|' breaks tables, ')' truncates links) is escaped in text and encoded in URLs
R16="$TMP/r16"; mkdir -p "$R16/o__r/rel"
printf 'repo: o/r\n' > "$R16/o__r/repo.yaml"
printf 'tag: "v1|x)y"\nchangeType: standard\nimpact: unnoticeable\nrisk: minor\nassessmentStatus: assessed\n' > "$R16/o__r/rel/release.yaml"
printf 'impact: unnoticeable\nrisk: minor\n' > "$R16/o__r/rel/pr-1.yaml"
bash "$SCRIPT" "$R16" >/dev/null 2>&1
repo16="$R16/o__r/repo.md"; rel16="$R16/o__r/rel/release.md"
{ grep -qF 'v1\|x\)y' "$repo16" \
  && grep -qF 'releases/tag/v1%7Cx%29y' "$rel16" \
  && ! grep -qF 'tag/v1|x)y' "$rel16"; } \
  && ok "T16 hostile tag escaped in text + encoded in URL" || no "T16" "$(cat "$repo16"; echo ---; cat "$rel16")"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
