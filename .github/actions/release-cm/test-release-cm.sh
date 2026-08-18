#!/usr/bin/env bash
# Self-contained regression tests for release-cm.sh.
# Builds a mock `gh` + fixtures in a temp dir and asserts behaviour with DRY_RUN.
# Requires: bash, jq. Run: bash test-release-cm.sh   (exit 0 = all pass)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-cm.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIXROOT="$TMP/fix"; mkdir -p "$TMP/bin" "$FIXROOT"

cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
FIX="${FIX:?}"
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  [ -f "$FIX/pr-list-fail" ] && { echo "error: HTTP 403" >&2; exit 1; }; exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  case "$*" in
    *publishedAt*) cat "$FIX/published.txt" 2>/dev/null || echo null; exit 0;;
    *body*)        cat "$FIX/release-body.txt" 2>/dev/null || echo ""; exit 0;;
  esac
fi
if [ "$1" = "release" ] && [ "$2" = "list" ]; then
  jq -Rn '[inputs|select(length>0)|split(" ")|{tagName:.[0],isDraft:(.[1]=="draft"),isPrerelease:(.[1]=="pre")}]' < "$FIX/releases.txt" 2>/dev/null || echo "[]"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  num="$3"
  if   [ -f "$FIX/pr-$num.json" ]; then cat "$FIX/pr-$num.json"; exit 0
  elif [ -f "$FIX/pr-$num.err" ];  then cat "$FIX/pr-$num.err" >&2; exit 1
  else echo "GraphQL: Could not resolve to a PullRequest with the number $num." >&2; exit 1; fi
fi
exit 0
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

echo "serviceIds: [572778]" > "$FIXROOT/snow-inline.yml"

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; printf '      %s\n' "$2"; fail=$((fail+1)); }
# assert_contains name needle ; assert_exit name expected
run(){ OUT=$( cd "$FIXROOT/$1" 2>/dev/null; FIX="$FIXROOT/$1" SNOW_YML="${SNOW:-$FIXROOT/snow-inline.yml}" REPO=x/y DRY_RUN=1 bash "$SCRIPT" "$2" 2>&1 ); RC=$?; }
has(){ case "$OUT" in *"$1"*) return 0;; *) return 1;; esac; }
mkfix(){ mkdir -p "$FIXROOT/$1"; }
mkpr(){ jq -n --arg a "$3" --arg b "$4" --argjson rv "$5" --argjson lb "$6" '{author:{login:$a},labels:$lb,reviews:$rv,body:$b}' > "$FIXROOT/$1/pr-$2.json"; }
NOREV='[]'; NOLBL='[]'
blk(){ printf '## Change Management\n\n```yaml\ncm-assessment: v1\n%s\n```\n' "$1"; }

# ---------- T1 partial (assessed + unassessed) ----------
mkfix T1; printf 'fixes #101 and #102\n' > "$FIXROOT/T1/release-body.txt"; echo 2026-08-18T00:00:00Z > "$FIXROOT/T1/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T1/releases.txt"
mkpr T1 101 alice "$(blk 'impact: degradation
risk: major')" '[{"author":{"login":"bob"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
mkpr T1 102 carol 'routine' "$NOREV" "$NOLBL"
run T1 v2
{ has 'impact: degradation' && has 'risk: major' && has 'changeType: normal' && has 'assessmentStatus: partial' && [ "$RC" -eq 0 ]; } \
  && ok "T1 partial aggregation" || no "T1 partial aggregation" "$OUT"

# ---------- T2 all assessed ----------
mkfix T2; printf 'fixes #201\n' > "$FIXROOT/T2/release-body.txt"; echo null > "$FIXROOT/T2/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T2/releases.txt"
mkpr T2 201 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
run T2 v2
{ has 'assessmentStatus: assessed' && has 'impact: unnoticeable' && [ "$RC" -eq 0 ]; } && ok "T2 assessed low-risk" || no "T2 assessed low-risk" "$OUT"

# ---------- T3 unassessed ----------
mkfix T3; printf 'fixes #301\n' > "$FIXROOT/T3/release-body.txt"; echo null > "$FIXROOT/T3/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T3/releases.txt"
mkpr T3 301 alice 'no block here' "$NOREV" "$NOLBL"
run T3 v2
{ has 'assessmentStatus: unassessed' && [ "$RC" -eq 0 ]; } && ok "T3 unassessed" || no "T3 unassessed" "$OUT"

# ---------- T4 invalid enum -> needs-review (NOT abort) ----------
mkfix T4; printf 'fixes #401\n' > "$FIXROOT/T4/release-body.txt"; echo null > "$FIXROOT/T4/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T4/releases.txt"
mkpr T4 401 alice "$(blk 'impact: degraded
risk: major')" "$NOREV" "$NOLBL"
run T4 v2
{ has 'assessmentStatus: needs-review' && has 'impact: unknown' && [ "$RC" -eq 0 ]; } && ok "T4 invalid enum -> needs-review" || no "T4 invalid enum -> needs-review" "$OUT"

# ---------- T5 unfenced block -> needs-review ----------
mkfix T5; printf 'fixes #501\n' > "$FIXROOT/T5/release-body.txt"; echo null > "$FIXROOT/T5/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T5/releases.txt"
mkpr T5 501 alice 'cm-assessment: v1
impact: outage
risk: major' "$NOREV" "$NOLBL"
run T5 v2
{ has 'assessmentStatus: needs-review' && [ "$RC" -eq 0 ]; } && ok "T5 unfenced -> needs-review" || no "T5 unfenced -> needs-review" "$OUT"

# ---------- T6 label vs low assessment -> needs-review + floor ----------
mkfix T6; printf 'fixes #601\n' > "$FIXROOT/T6/release-body.txt"; echo null > "$FIXROOT/T6/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T6/releases.txt"
mkpr T6 601 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" '[{"name":"cmr:high-risk"}]'
run T6 v2
{ has 'assessmentStatus: needs-review' && has 'impact: degradation' && has 'risk: major' && [ "$RC" -eq 0 ]; } \
  && ok "T6 label/assessment conflict" || no "T6 label/assessment conflict" "$OUT"

# ---------- T7 duplicate block, last wins ----------
mkfix T7; printf 'fixes #701\n' > "$FIXROOT/T7/release-body.txt"; echo null > "$FIXROOT/T7/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T7/releases.txt"
mkpr T7 701 alice "$(blk 'impact: unnoticeable
risk: minor')
$(blk 'impact: degradation
risk: major')" "$NOREV" "$NOLBL"
run T7 v2
{ has 'impact: degradation' && has 'assessmentStatus: assessed' && [ "$RC" -eq 0 ]; } && ok "T7 duplicate last-wins" || no "T7 duplicate last-wins" "$OUT"

# ---------- T8 AI-agent approves bot PR -> independent true ----------
mkfix T8; printf 'fixes #801\n' > "$FIXROOT/T8/release-body.txt"; echo null > "$FIXROOT/T8/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T8/releases.txt"
mkpr T8 801 'renovate[bot]' 'bump' '[{"author":{"login":"claude[bot]"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T8 v2
{ has 'independentlyApproved: true' && [ "$RC" -eq 0 ]; } && ok "T8 AI-agent approval is independent" || no "T8 AI-agent approval is independent" "$OUT"

# ---------- T9 stale approve-then-changes-requested -> not counted ----------
mkfix T9; printf 'fixes #901\n' > "$FIXROOT/T9/release-body.txt"; echo null > "$FIXROOT/T9/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T9/releases.txt"
mkpr T9 901 alice 'x' '[{"author":{"login":"bob"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"bob"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T9 v2
{ has 'approvedBy: []' && has 'independentlyApproved: false' && [ "$RC" -eq 0 ]; } && ok "T9 stale approval excluded" || no "T9 stale approval excluded" "$OUT"

# ---------- T10 missing .snow.yml -> abort ----------
mkfix T10; printf 'fixes #1001\n' > "$FIXROOT/T10/release-body.txt"; echo null > "$FIXROOT/T10/published.txt"; printf 'v2\n' > "$FIXROOT/T10/releases.txt"
SNOW="$FIXROOT/does-not-exist.yml" run T10 v2
{ has '::error::' && [ "$RC" -ne 0 ] && ! has 'cm-attributes: v1'; } && ok "T10 missing .snow.yml aborts" || no "T10 missing .snow.yml aborts" "$OUT"

# ---------- T11 malformed .snow.yml mid-entry -> abort ----------
printf 'serviceIds:\n  - 572778\n  - nope\n  - 572779\n' > "$FIXROOT/snow-bad.yml"
mkfix T11; printf 'fixes #1101\n' > "$FIXROOT/T11/release-body.txt"; echo null > "$FIXROOT/T11/published.txt"; printf 'v2\n' > "$FIXROOT/T11/releases.txt"
SNOW="$FIXROOT/snow-bad.yml" run T11 v2
{ has '::error::' && [ "$RC" -ne 0 ]; } && ok "T11 malformed .snow.yml aborts" || no "T11 malformed .snow.yml aborts" "$OUT"

# ---------- T12 capability probe fails -> abort ----------
mkfix T12; printf 'fixes #1 #2 #3\n' > "$FIXROOT/T12/release-body.txt"; echo null > "$FIXROOT/T12/published.txt"; printf 'v2\n' > "$FIXROOT/T12/releases.txt"; touch "$FIXROOT/T12/pr-list-fail"
run T12 v2
{ has 'cannot list pull requests' && [ "$RC" -ne 0 ] && ! has 'cm-attributes: v1'; } && ok "T12 no PR scope aborts" || no "T12 no PR scope aborts" "$OUT"

# ---------- T13 issue-only refs -> no false abort ----------
mkfix T13; printf 'closes #1301 and #1302\n' > "$FIXROOT/T13/release-body.txt"; echo null > "$FIXROOT/T13/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T13/releases.txt"
run T13 v2
{ has 'changes: []' && has 'assessmentStatus: unassessed' && [ "$RC" -eq 0 ]; } && ok "T13 issue-only proceeds" || no "T13 issue-only proceeds" "$OUT"

# ---------- T14 idempotent (already decorated) -> skip ----------
mkfix T14; printf 'notes\n\n## Change Management\n\n```yaml\ncm-attributes: v1\nserviceIds: [1]\n```\n' > "$FIXROOT/T14/release-body.txt"; echo null > "$FIXROOT/T14/published.txt"; printf 'v2\n' > "$FIXROOT/T14/releases.txt"
run T14 v2
{ has 'already has a change-management block' && [ "$RC" -eq 0 ] && ! has 'DRY RUN'; } && ok "T14 idempotent skip" || no "T14 idempotent skip" "$OUT"

# ---------- T15 carry PR backout field ----------
mkfix T15; printf 'fixes #1501\n' > "$FIXROOT/T15/release-body.txt"; echo null > "$FIXROOT/T15/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T15/releases.txt"
mkpr T15 1501 alice "$(blk 'impact: degradation
risk: major
backout: "revert the DB migration 004"')" "$NOREV" "$NOLBL"
run T15 v2
{ has 'backout: "revert the DB migration 004"' && [ "$RC" -eq 0 ]; } && ok "T15 carries PR backout" || no "T15 carries PR backout" "$OUT"

# ---------- T16 all no-impact -> reachable ----------
mkfix T16; printf 'fixes #1601\n' > "$FIXROOT/T16/release-body.txt"; echo null > "$FIXROOT/T16/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T16/releases.txt"
mkpr T16 1601 alice "$(blk 'impact: no-impact
risk: minor')" "$NOREV" "$NOLBL"
run T16 v2
{ has 'impact: no-impact' && [ "$RC" -eq 0 ]; } && ok "T16 no-impact reachable" || no "T16 no-impact reachable" "$OUT"

# ---------- T17 transient gh error -> abort ----------
mkfix T17; printf 'fixes #1701\n' > "$FIXROOT/T17/release-body.txt"; echo null > "$FIXROOT/T17/published.txt"; printf 'v2\n' > "$FIXROOT/T17/releases.txt"
echo 'error: API rate limit exceeded' > "$FIXROOT/T17/pr-1701.err"
run T17 v2
{ has '::error::' && has 'failed to look up PR #1701' && [ "$RC" -ne 0 ]; } && ok "T17 transient gh error aborts" || no "T17 transient gh error aborts" "$OUT"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
