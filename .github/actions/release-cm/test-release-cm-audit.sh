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
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then exit 0; fi
if [ "$1" = "release" ] && [ "$2" = "list" ]; then
  jq -Rn '[inputs|select(length>0)|split("\t")|{tagName:.[0],publishedAt:.[1],isDraft:(.[2]=="draft"),isPrerelease:(.[2]=="pre")}]' < "$FIX/releases.tsv"
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  tag="$3"
  case "$*" in
    *publishedAt*) awk -F'\t' -v t="$tag" '$1==t{print $2}' "$FIX/releases.tsv"; exit 0;;
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
printf 'notes\n\n## Change Management\n\n```yaml\ncm-attributes: v1\nserviceIds: [1]\n```\n' > "$FIX/body-v1.0.0.txt"
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
  && has 'SUGGEST  v1.2.0' && has 'assessmentStatus=unassessed' \
  && has 'suggested 2' && [ "$RC" -eq 0 ]; } \
  && ok "suggest shows blocks + status, no writes" || no "suggest" "$OUT"

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

# ---- OUT_DIR artifact persistence (manifest + per-release block) ----
AOUT="$TMP/artifacts"
OUT=$( SNOW_YML="$TMP/snow.yml" REPO=x/y OUT_DIR="$AOUT" bash "$AUDIT" 2026-01-01 suggest 2>&1 ); RC=$?
{ [ -f "$AOUT/manifest.md" ] && grep -q '| v1.1.0 |' "$AOUT/manifest.md" && [ -f "$AOUT/v1.1.0.cm.yaml" ] \
  && { ! command -v ruby >/dev/null 2>&1 || ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$AOUT/v1.1.0.cm.yaml" >/dev/null 2>&1; } \
  && has 'artifacts written to' && [ "$RC" -eq 0 ]; } \
  && ok "OUT_DIR persists manifest + valid per-release block" || no "OUT_DIR artifacts" "$OUT"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
