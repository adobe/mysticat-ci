#!/usr/bin/env bash
# Tests for release-cm-audit.sh (report/suggest/fix) over a mock repo's releases.
# Requires: bash, jq. Run: bash test-release-cm-audit.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AUDIT="$HERE/release-cm-audit.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$TMP/bin" "$FIX"; export FIX

cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
FIX="${FIX:?}"
if [ "$1" = "api" ] && [ "${2#users/}" != "$2" ]; then jq -n '{type:"User",name:""}'; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then exit 0; fi
if [ "$1" = "release" ] && [ "$2" = "list" ]; then
  jq -Rn '[inputs|select(length>0)|split("\t")|{tagName:.[0],publishedAt:.[1],isDraft:(.[2]=="draft"),isPrerelease:(.[2]=="pre")}]' < "$FIX/releases.tsv"
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  tag="$3"
  case "$*" in
    *publishedAt*) awk -F'\t' -v t="$tag" '$1==t{print $2}' "$FIX/releases.tsv"; exit 0;;
    *author*)      echo relmgr; exit 0;;
    *body*)        cat "$FIX/body-$tag.txt" 2>/dev/null || echo ""; exit 0;;
  esac
fi
if [ "$1" = "release" ] && [ "$2" = "edit" ]; then echo edited; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  n="$3"
  if [ -f "$FIX/pr-$n.json" ]; then cat "$FIX/pr-$n.json"; exit 0; fi
  echo "GraphQL: Could not resolve to a PullRequest with the number $n." >&2; exit 1
fi
exit 0
SH
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"
echo "serviceIds: [572778]" > "$TMP/snow.yml"

# Releases (newest first so release-cm.sh prev-resolution works): tag<TAB>publishedAt<TAB>flag
printf '%s\n' \
  "v1.3.0-rc.1	2026-04-01T00:00:00Z	pre" \
  "v1.2.0	2026-03-01T00:00:00Z	" \
  "v1.1.0	2026-02-01T00:00:00Z	" \
  "v1.0.0	2026-01-15T00:00:00Z	" \
  "v0.9.0	2025-12-01T00:00:00Z	" > "$FIX/releases.tsv"
# v1.0.0 already covered; v1.1.0 gap with an assessed PR; v1.2.0 gap, no PRs; v0.9.0 too old; rc excluded
# a DECOY ```yaml``` block precedes the CM block — write_release must anchor on cm-attributes, not the first fence
printf 'notes\n\n```yaml\nexample: changelog\nfoo: bar\n```\n\n## Change Management\n\n```yaml\ncm-attributes: v1\nserviceIds: [1]\nchangeType: normal\nimpact: outage\nrisk: major\nassessmentStatus: assessed\nassessedCoverage: "1/1"\n```\n' > "$FIX/body-v1.0.0.txt"
printf 'fixes #10\n' > "$FIX/body-v1.1.0.txt"
printf 'chore: docs only\n' > "$FIX/body-v1.2.0.txt"
printf 'old\n' > "$FIX/body-v0.9.0.txt"
printf 'rc\n' > "$FIX/body-v1.3.0-rc.1.txt"
jq -n '{author:{login:"alice"},labels:[],reviews:[],body:"## Change Management\n\n```yaml\ncm-assessment: v1\nimpact: degradation\nrisk: major\n```\n"}' > "$FIX/pr-10.json"

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; printf '%s\n' "$2" | sed 's/^/      /'; fail=$((fail+1)); }
has(){ case "$OUT" in *"$1"*) return 0;; *) return 1;; esac; }
runa(){ OUT=$( SNOW_YML="${SNOW:-$TMP/snow.yml}" REPO=x/y bash "$AUDIT" "$1" "$2" 2>&1 ); RC=$?; }

# ---- report ----
runa 2026-01-01 report
{ has 'GAP      v1.1.0' && has 'GAP      v1.2.0' && ! has 'v0.9.0' && ! has 'v1.3.0-rc.1' \
  && has '3 production release(s) since 2026-01-01: 1 already covered, 2 missing' && [ "$RC" -eq 0 ]; } \
  && ok "report lists gaps, excludes old/prerelease/covered" || no "report" "$OUT"

# ---- suggest ----
runa 2026-01-01 suggest
{ has 'SUGGEST  v1.1.0' && has 'assessmentStatus=assessed' && has 'impact: degradation' \
  && has 'changeApprovedBy:' \
  && has 'SUGGEST  v1.2.0' && has 'assessmentStatus=unassessed' \
  && has 'suggested 2' && [ "$RC" -eq 0 ]; } \
  && ok "suggest shows blocks + status (incl. changeApprovedBy), no writes" || no "suggest" "$OUT"

# ---- fix ----
runa 2026-01-01 fix
{ has 'FIXED    v1.1.0' && has 'FIXED    v1.2.0' && has 'fixed 2' && has '0 could not be generated' && [ "$RC" -eq 0 ]; } \
  && ok "fix backfills the gaps" || no "fix" "$OUT"

# ---- fix with missing .snow.yml -> per-release FAILED, exit 1 ----
SNOW="$TMP/nope.yml" runa 2026-01-01 fix
{ has 'FAILED   v1.1.0' && has 'FAILED   v1.2.0' && [ "$RC" -ne 0 ]; } \
  && ok "fix fails closed (missing .snow.yml) and exits non-zero" || no "fix-failclosed" "$OUT"

# ---- bad args ----
runa 2026-1-1 report; { [ "$RC" -eq 2 ]; } && ok "rejects malformed date" || no "date-validation" "$OUT (rc=$RC)"
runa 2026-01-01 bogus; { [ "$RC" -eq 2 ]; } && ok "rejects bad mode" || no "mode-validation" "$OUT (rc=$RC)"

# ---- RUN persists the shared NESTED layout that cmr-report.sh consumes ----
AOUT="$TMP/run"
OUT=$( SNOW_YML="$TMP/snow.yml" REPO=x/y RUN="$AOUT" bash "$AUDIT" 2026-01-01 suggest 2>&1 ); RC=$?
RELY="$AOUT/x__y/v1.1.0/release.yaml"
{ [ -f "$AOUT/x__y/repo.yaml" ] && grep -q '^repo: x/y' "$AOUT/x__y/repo.yaml" \
  && [ -f "$RELY" ] && grep -q '^tag: "v1.1.0"' "$RELY" && grep -q '^impact: degradation' "$RELY" \
  && [ -f "$AOUT/x__y/v1.1.0/pr-10.yaml" ] && grep -q '^pr: 10' "$AOUT/x__y/v1.1.0/pr-10.yaml" \
  && grep -q '^impact: degradation' "$AOUT/x__y/v1.1.0/pr-10.yaml" && grep -q '^risk: major' "$AOUT/x__y/v1.1.0/pr-10.yaml" \
  && { ! command -v ruby >/dev/null 2>&1 || ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$RELY" >/dev/null 2>&1; } \
  && has 'render the tree with' && [ "$RC" -eq 0 ]; } \
  && ok "RUN persists nested repo/release/pr data" || no "RUN nested artifacts" "$OUT"

# a COVERED release keeps its real changeType/impact/risk (parsed from the existing block), not a bare label
COVY="$AOUT/x__y/v1.0.0/release.yaml"
{ [ -f "$COVY" ] && grep -q '^impact: outage' "$COVY" && grep -q '^changeType: normal' "$COVY" \
  && grep -q '^assessmentStatus: assessed' "$COVY"; } \
  && ok "covered release keeps real block values" || no "covered real data" "$(cat "$COVY" 2>/dev/null)"

# ---- the audit's data renders cleanly through cmr-report.sh (one shared scheme) ----
REPORT="$HERE/cmr-report.sh"
if [ -f "$REPORT" ]; then
  bash "$REPORT" "$AOUT" --mode suggest --since 2026-01-01 >/dev/null 2>&1
  { [ -f "$AOUT/README.md" ] && [ -f "$AOUT/x__y/repo.md" ] && [ -f "$AOUT/x__y/v1.1.0/release.md" ] \
    && grep -q '/pull/10' "$AOUT/x__y/v1.1.0/release.md"; } \
    && ok "audit data renders through cmr-report" || no "audit->cmr-report" "$(cat "$AOUT/README.md" 2>/dev/null)"
else
  no "audit->cmr-report" "cmr-report.sh not found next to audit script"
fi

# ---- fix mode writes CORRECT data with a STATEFUL gh (regression: 2nd-DRY idempotency bug) ----
# A real `release edit` persists the notes; the audit must capture the block from a DRY BEFORE
# the edit, else the post-edit read hits the idempotency guard and writes `unassessed`/no PRs.
BIN2="$TMP/bin2"; F2="$TMP/fix2"; mkdir -p "$BIN2" "$F2"
cat > "$BIN2/gh" <<'SH'
#!/usr/bin/env bash
FIX="${FIX:?}"
if [ "$1" = "api" ] && [ "${2#users/}" != "$2" ]; then jq -n '{type:"User",name:""}'; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then exit 0; fi
if [ "$1" = "release" ] && [ "$2" = "list" ]; then
  jq -Rn '[inputs|select(length>0)|split("\t")|{tagName:.[0],publishedAt:.[1],isDraft:false,isPrerelease:false}]' < "$FIX/releases.tsv"; exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  tag="$3"
  case "$*" in
    *publishedAt*) awk -F'\t' -v t="$tag" '$1==t{print $2}' "$FIX/releases.tsv"; exit 0;;
    *author*)      echo relmgr; exit 0;;
    *body*)        cat "$FIX/body-$tag.txt" 2>/dev/null || echo ""; exit 0;;
  esac
fi
if [ "$1" = "release" ] && [ "$2" = "edit" ]; then
  tag="$3"; notes=""; while [ $# -gt 0 ]; do [ "$1" = "--notes" ] && { notes="$2"; break; }; shift; done
  [ -n "$notes" ] && printf '%s' "$notes" > "$FIX/body-$tag.txt"; echo edited; exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  n="$3"; [ -f "$FIX/pr-$n.json" ] && { cat "$FIX/pr-$n.json"; exit 0; }
  echo "no pr $n" >&2; exit 1
fi
exit 0
SH
chmod +x "$BIN2/gh"
printf 'v9.9.9\t2026-05-01T00:00:00Z\t\n' > "$F2/releases.tsv"
printf 'fixes #909\n' > "$F2/body-v9.9.9.txt"
jq -n '{author:{login:"al"},labels:[],reviews:[],body:"## Change Management\n\n```yaml\ncm-assessment: v1\nimpact: degradation\nrisk: major\n```\n"}' > "$F2/pr-909.json"
RUN2="$TMP/run2"
OUT=$( PATH="$BIN2:$PATH" FIX="$F2" SNOW_YML="$TMP/snow.yml" REPO=x/y RUN="$RUN2" bash "$AUDIT" 2026-01-01 fix 2>&1 ); RC=$?
RELY2="$RUN2/x__y/v9.9.9/release.yaml"
PRY2="$RUN2/x__y/v9.9.9/pr-909.yaml"
{ has 'FIXED    v9.9.9' && [ -f "$RELY2" ] && grep -q '^impact: degradation' "$RELY2" && grep -q '^risk: major' "$RELY2" \
  && ! grep -q '^assessmentStatus: unassessed' "$RELY2" \
  && [ -f "$PRY2" ] && grep -q '^impact: degradation' "$PRY2" && grep -q '^risk: major' "$PRY2" && [ "$RC" -eq 0 ]; } \
  && ok "fix persists real data (stateful gh, DRY-before-edit)" || no "fix data regression" "$OUT
--- release.yaml ---
$(cat "$RELY2" 2>/dev/null)
--- pr-909.yaml ---
$(cat "$PRY2" 2>/dev/null)"

# ---- suggest never aborts when a gap PR has no assessment (empty risk row; set -e safety) ----
F3="$TMP/fix3"; mkdir -p "$F3"
printf 'v8.0.0\t2026-05-01T00:00:00Z\t\n' > "$F3/releases.tsv"
printf 'fixes #808\n' > "$F3/body-v8.0.0.txt"
jq -n '{author:{login:"al"},labels:[],reviews:[],body:"no assessment here"}' > "$F3/pr-808.json"
OUT=$( FIX="$F3" SNOW_YML="$TMP/snow.yml" REPO=x/y RUN="$TMP/run3" bash "$AUDIT" 2026-01-01 suggest 2>&1 ); RC=$?
{ has 'SUGGEST  v8.0.0' && has 'render the tree with' && [ "$RC" -eq 0 ]; } \
  && ok "suggest with an unassessed PR does not abort (set -e)" || no "suggest set -e abort" "$OUT (rc=$RC)"

# ---- tagsafe is injective: two distinct tags that sanitise alike land in DIFFERENT folders ----
F4="$TMP/fix4"; mkdir -p "$F4"
printf 'v7.0/rc1\t2026-05-01T00:00:00Z\t\nv7.0_rc1\t2026-05-02T00:00:00Z\t\n' > "$F4/releases.tsv"
# no body files: `release view --body` returns empty -> both are gaps (report mode, no writes to GitHub)
OUT=$( FIX="$F4" SNOW_YML="$TMP/snow.yml" REPO=x/y RUN="$TMP/run4" bash "$AUDIT" 2026-01-01 report 2>&1 ); RC=$?
ndirs=$(find "$TMP/run4/x__y" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
{ [ "$ndirs" -eq 2 ] && [ "$RC" -eq 0 ]; } \
  && ok "tagsafe injective: distinct tags -> distinct folders" || no "tagsafe collision" "ndirs=$ndirs rc=$RC
$OUT"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
