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
    *author*)      cat "$FIX/release-author.txt" 2>/dev/null || echo relmgr; exit 0;;  # publisher (human default)
    *body*)        [ -f "$FIX/release-view-fail" ] && { echo "HTTP 502" >&2; exit 1; }
                   cat "$FIX/release-body.txt" 2>/dev/null || echo ""; exit 0;;
  esac
fi
if [ "$1" = "api" ] && [ "${2#users/}" != "$2" ]; then   # users/<login> profile lookup -> JSON
  login="${2#users/}"
  if [ -f "$FIX/user-$login.json" ]; then cat "$FIX/user-$login.json"
  else nm=$(cat "$FIX/user-$login.txt" 2>/dev/null || echo ""); jq -n --arg n "$nm" '{type:"User",name:$n}'; fi
  exit 0
fi
if [ "$1" = "release" ] && [ "$2" = "edit" ]; then
  [ -f "$FIX/release-edit-fail" ] && { echo "HTTP 403" >&2; exit 1; }
  echo edited; exit 0
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
# yaml_ok: parse the emitted ```yaml block (via ruby if present; skip if no parser).
yaml_ok(){
  command -v ruby >/dev/null 2>&1 || return 0
  printf '%s\n' "$OUT" | awk '/```yaml/{f=1;next}/```/{f=0}f' | ruby -ryaml -e 'YAML.safe_load(STDIN.read)' >/dev/null 2>&1
}
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

# ---------- T7 conflicting blocks -> needs-review (a human must reduce to one) ----------
mkfix T7; printf 'fixes #701\n' > "$FIXROOT/T7/release-body.txt"; echo null > "$FIXROOT/T7/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T7/releases.txt"
mkpr T7 701 alice "$(blk 'impact: unnoticeable
risk: minor')
$(blk 'impact: degradation
risk: major')" "$NOREV" "$NOLBL"
run T7 v2
{ has 'assessmentStatus: needs-review' && has 'impact: unknown' && has 'note: "multiple conflicting' && [ "$RC" -eq 0 ]; } \
  && ok "T7 conflicting blocks -> needs-review" || no "T7 conflicting blocks -> needs-review" "$OUT"

# ---------- T7b IDENTICAL duplicate blocks (no disagreement) -> still assessed ----------
mkfix T7b; printf 'fixes #702\n' > "$FIXROOT/T7b/release-body.txt"; echo null > "$FIXROOT/T7b/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T7b/releases.txt"
mkpr T7b 702 alice "$(blk 'impact: degradation
risk: major')
$(blk 'impact: degradation
risk: major')" "$NOREV" "$NOLBL"
run T7b v2
{ has 'impact: degradation' && has 'assessmentStatus: assessed' && ! has 'assessmentStatus: needs-review' && [ "$RC" -eq 0 ]; } \
  && ok "T7b identical duplicate blocks -> assessed" || no "T7b identical duplicate blocks -> assessed" "$OUT"

# ---------- T7c unclosed block hidden behind a well-formed sibling -> needs-review ----------
mkfix T7c; printf 'fixes #703\n' > "$FIXROOT/T7c/release-body.txt"; echo null > "$FIXROOT/T7c/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T7c/releases.txt"
mkpr T7c 703 alice 'cm-assessment: v1
impact: outage
risk: major
cm-assessment: v1
impact: unnoticeable
risk: minor
```' "$NOREV" "$NOLBL"
run T7c v2
{ has 'assessmentStatus: needs-review' && has 'impact: unknown' && has 'not closed by a fence' && [ "$RC" -eq 0 ]; } \
  && ok "T7c unclosed block behind a sibling -> needs-review" || no "T7c unclosed-then-closed" "$OUT"

# ---------- T7d partial conflict (agree on impact/risk, differ on changeType) ----------
# per-PR shows unknown + needs-review, but the AGREED degradation/major must not be floored away
mkfix T7d; printf 'fixes #704\n' > "$FIXROOT/T7d/release-body.txt"; echo null > "$FIXROOT/T7d/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T7d/releases.txt"
mkpr T7d 704 alice "$(blk 'changeType: normal
impact: degradation
risk: major')
$(blk 'changeType: standard
impact: degradation
risk: major')" "$NOREV" "$NOLBL"
run T7d v2
{ has 'assessmentStatus: needs-review' && has 'impact: degradation' && has 'risk: major' \
  && has 'impact: unknown' && has 'risk: unknown' && [ "$RC" -eq 0 ]; } \
  && ok "T7d partial conflict: aggregate kept, per-PR unknown" || no "T7d partial conflict" "$OUT"

# ---------- T8 AI reviewer (MysticatBot) approval is NOT an independent human (CM Standard) ----------
# MysticatBot is a GitHub "User" (not a *[bot] login), so it must be caught by the hardcoded
# denylist. approvedBy still lists it (transparency); independentlyApproved must be false.
mkfix T8; printf 'fixes #801\n' > "$FIXROOT/T8/release-body.txt"; echo null > "$FIXROOT/T8/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T8/releases.txt"
mkpr T8 801 alice 'bump' '[{"author":{"login":"MysticatBot"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T8 v2
{ has 'independentlyApproved: false' && has 'approvalControl: automated' && has 'approvedBy: ["MysticatBot"]' && [ "$RC" -eq 0 ]; } \
  && ok "T8 AI reviewer approval is not independent (approvalControl: automated)" || no "T8 AI reviewer approval is not independent" "$OUT"

# ---------- T9 stale approve-then-changes-requested -> not counted ----------
mkfix T9; printf 'fixes #901\n' > "$FIXROOT/T9/release-body.txt"; echo null > "$FIXROOT/T9/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T9/releases.txt"
mkpr T9 901 alice 'x' '[{"author":{"login":"bob"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"bob"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T9 v2
{ has 'approvedBy: []' && has 'independentlyApproved: false' && has 'approvalControl: none' && [ "$RC" -eq 0 ]; } && ok "T9 stale approval excluded (approvalControl: none)" || no "T9 stale approval excluded" "$OUT"

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

# ---------- T18 backout with embedded quotes -> valid YAML ----------
mkfix T18; printf 'fixes #1801\n' > "$FIXROOT/T18/release-body.txt"; echo null > "$FIXROOT/T18/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T18/releases.txt"
mkpr T18 1801 alice "$(blk 'impact: degradation
risk: major
backout: revert then run "terraform apply" in "prod"')" "$NOREV" "$NOLBL"
run T18 v2
{ yaml_ok && has 'backout:' && has 'terraform apply' && [ "$RC" -eq 0 ]; } && ok "T18 backout with quotes -> valid YAML" || no "T18 backout with quotes -> valid YAML" "$OUT"

# ---------- T19 multi-line block-scalar backout -> needs-review, no garbage ----------
mkfix T19; printf 'fixes #1901\n' > "$FIXROOT/T19/release-body.txt"; echo null > "$FIXROOT/T19/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T19/releases.txt"
mkpr T19 1901 alice 'started
## Change Management

```yaml
cm-assessment: v1
impact: degradation
risk: major
backout: |
  step 1
  step 2
```' "$NOREV" "$NOLBL"
run T19 v2
{ has 'assessmentStatus: needs-review' && ! has 'backout: "|"' && has 'impact: degradation' && yaml_ok && [ "$RC" -eq 0 ]; } \
  && ok "T19 block-scalar backout flagged, no garbage" || no "T19 block-scalar backout flagged, no garbage" "$OUT"

# ---------- T20 partial-field-invalid -> per-field display (BUG2) ----------
mkfix T20; printf 'fixes #2001\n' > "$FIXROOT/T20/release-body.txt"; echo null > "$FIXROOT/T20/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T20/releases.txt"
mkpr T20 2001 alice "$(blk 'impact: bogus
risk: major')" "$NOREV" "$NOLBL"
run T20 v2
# per-PR entry must show impact: unknown AND risk: major (the valid field preserved), status needs-review
{ has 'impact: unknown' && has 'risk: major' && has 'assessmentStatus: needs-review' && yaml_ok && [ "$RC" -eq 0 ]; } \
  && ok "T20 partial-invalid keeps valid field" || no "T20 partial-invalid keeps valid field" "$OUT"

# ---------- T21 three-way mix (assessed + needs-review + unassessed) ----------
mkfix T21; printf 'fixes #2101 #2102 #2103\n' > "$FIXROOT/T21/release-body.txt"; echo null > "$FIXROOT/T21/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T21/releases.txt"
mkpr T21 2101 alice "$(blk 'impact: degradation
risk: major')" "$NOREV" "$NOLBL"
mkpr T21 2102 bob "$(blk 'impact: nope')" "$NOREV" "$NOLBL"
mkpr T21 2103 carol 'plain' "$NOREV" "$NOLBL"
run T21 v2
{ has 'assessmentStatus: needs-review' && has 'impact: degradation' && yaml_ok && [ "$RC" -eq 0 ]; } \
  && ok "T21 three-way mix -> needs-review wins" || no "T21 three-way mix -> needs-review wins" "$OUT"

# ---------- T22 case-insensitive enum accepted (positive path) ----------
mkfix T22; printf 'fixes #2201\n' > "$FIXROOT/T22/release-body.txt"; echo null > "$FIXROOT/T22/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T22/releases.txt"
mkpr T22 2201 alice "$(blk 'impact: DEGRADATION
risk: Major
changeType: Normal')" "$NOREV" "$NOLBL"
run T22 v2
{ has 'impact: degradation' && has 'risk: major' && has 'assessmentStatus: assessed' && [ "$RC" -eq 0 ]; } \
  && ok "T22 case-insensitive accepted" || no "T22 case-insensitive accepted" "$OUT"

# ---------- T23 high-risk label, no conflict (already high) -> assessed, not needs-review ----------
mkfix T23; printf 'fixes #2301\n' > "$FIXROOT/T23/release-body.txt"; echo null > "$FIXROOT/T23/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T23/releases.txt"
mkpr T23 2301 alice "$(blk 'impact: degradation
risk: major')" "$NOREV" '[{"name":"cmr:high-risk"}]'
run T23 v2
{ has 'assessmentStatus: assessed' && ! has 'assessmentStatus: needs-review' && [ "$RC" -eq 0 ]; } \
  && ok "T23 label w/o conflict stays assessed" || no "T23 label w/o conflict stays assessed" "$OUT"

# ---------- T24 release body read failure -> abort ----------
mkfix T24; printf 'x\n' > "$FIXROOT/T24/release-body.txt"; echo null > "$FIXROOT/T24/published.txt"; printf 'v2\n' > "$FIXROOT/T24/releases.txt"; touch "$FIXROOT/T24/release-view-fail"
run T24 v2
{ has '::error::' && has 'cannot read release' && [ "$RC" -ne 0 ] && ! has 'cm-attributes: v1'; } \
  && ok "T24 body read failure aborts" || no "T24 body read failure aborts" "$OUT"

# ---------- T25 non-DRY edit path (writes) ----------
mkfix T25; printf 'fixes #2501\n' > "$FIXROOT/T25/release-body.txt"; echo null > "$FIXROOT/T25/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T25/releases.txt"
mkpr T25 2501 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
OUT=$( cd "$FIXROOT/T25"; FIX="$FIXROOT/T25" SNOW_YML="$FIXROOT/snow-inline.yml" REPO=x/y bash "$SCRIPT" v2 2>&1 ); RC=$?
{ has 'decorated x/y release v2' && ! has 'DRY RUN' && [ "$RC" -eq 0 ]; } && ok "T25 non-DRY edit path writes" || no "T25 non-DRY edit path writes" "$OUT"

# ---------- T26 non-DRY edit failure -> die ----------
mkfix T26; printf 'fixes #2601\n' > "$FIXROOT/T26/release-body.txt"; echo null > "$FIXROOT/T26/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T26/releases.txt"; touch "$FIXROOT/T26/release-edit-fail"
mkpr T26 2601 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
OUT=$( cd "$FIXROOT/T26"; FIX="$FIXROOT/T26" SNOW_YML="$FIXROOT/snow-inline.yml" REPO=x/y bash "$SCRIPT" v2 2>&1 ); RC=$?
{ has '::error::' && has 'failed to update release' && [ "$RC" -ne 0 ]; } && ok "T26 edit failure aborts" || no "T26 edit failure aborts" "$OUT"

# ---------- T27 github-actions[bot] (CI identity) approver -> NOT independent ----------
mkfix T27; printf 'fixes #2701\n' > "$FIXROOT/T27/release-body.txt"; echo null > "$FIXROOT/T27/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T27/releases.txt"
mkpr T27 2701 alice 'x' '[{"author":{"login":"github-actions[bot]"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T27 v2
{ has 'approvedBy: ["github-actions[bot]"]' && has 'independentlyApproved: false' && [ "$RC" -eq 0 ]; } \
  && ok "T27 CI identity not independent" || no "T27 CI identity not independent" "$OUT"

# ---------- T28 single-line backout that starts with > -> NOT flagged, kept ----------
mkfix T28; printf 'fixes #2801\n' > "$FIXROOT/T28/release-body.txt"; echo null > "$FIXROOT/T28/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T28/releases.txt"
mkpr T28 2801 alice "$(blk 'impact: degradation
risk: major
backout: "> rollback via the feature flag toggle"')" "$NOREV" "$NOLBL"
run T28 v2
{ has 'assessmentStatus: assessed' && has 'rollback via the feature flag toggle' && ! has 'assessmentStatus: needs-review' && yaml_ok && [ "$RC" -eq 0 ]; } \
  && ok "T28 free-text backout starting with > kept" || no "T28 free-text backout starting with > kept" "$OUT"

# ---------- T29 PR-declared emergency is clamped: a scheduled release is NOT emergency ----------
mkfix T29; printf 'fixes #2901\n' > "$FIXROOT/T29/release-body.txt"; echo null > "$FIXROOT/T29/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T29/releases.txt"
mkpr T29 2901 alice "$(blk 'changeType: emergency
impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
run T29 v2
{ has 'changeType: standard' && ! has 'changeType: emergency' && [ "$RC" -eq 0 ]; } && ok "T29 PR emergency clamped (release not emergency)" || no "T29 PR emergency clamped" "$OUT"

# ---------- T30 hotfix-style tag -> release changeType emergency ----------
mkfix T30; printf 'fixes #2902\n' > "$FIXROOT/T30/release-body.txt"; echo null > "$FIXROOT/T30/published.txt"; printf 'v2-hotfix-1\nv2\n' > "$FIXROOT/T30/releases.txt"
mkpr T30 2902 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
run T30 v2-hotfix-1
{ has 'changeType: emergency' && [ "$RC" -eq 0 ]; } && ok "T30 hotfix tag => emergency" || no "T30 hotfix tag => emergency" "$OUT"

# ---------- T31 reversible degradation (impact degradation, risk minor) stays standard ----------
mkfix T31; printf 'fixes #3100\n' > "$FIXROOT/T31/release-body.txt"; echo null > "$FIXROOT/T31/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T31/releases.txt"
mkpr T31 3100 alice "$(blk 'impact: degradation
risk: minor')" "$NOREV" "$NOLBL"
run T31 v2
{ has 'impact: degradation' && has 'risk: minor' && has 'changeType: standard' && ! has 'changeType: normal' && [ "$RC" -eq 0 ]; } \
  && ok "T31 reversible degradation stays standard (gate is risk, not impact)" || no "T31 reversible degradation stays standard" "$OUT"

# ---------- T32 fully automated (AI approval + bot publisher, no human) -> needs a human approver ----------
mkfix T32; printf 'fixes #3201\n' > "$FIXROOT/T32/release-body.txt"; echo null > "$FIXROOT/T32/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T32/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T32/release-author.txt"
mkpr T32 3201 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"MysticatBot"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T32 v2
{ has 'assessmentStatus: needs-review' && has 'no CM approver' && has 'changeApprovedBy: []' && [ "$RC" -eq 0 ]; } \
  && ok "T32 all-automation -> needs a CM approver" || no "T32 all-automation" "$OUT"

# ---------- T33 human PR approver -> release CM approver (name resolved); PR carries changeApprovedBy ----------
mkfix T33; printf 'fixes #3301\n' > "$FIXROOT/T33/release-body.txt"; echo null > "$FIXROOT/T33/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T33/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T33/release-author.txt"     # publisher is a bot -> CM approver must come from the human reviewer
echo 'Dana Scully' > "$FIXROOT/T33/user-dana.txt"
mkpr T33 3301 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"dana"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T33 v2
{ has 'changeApprovedBy: ["Dana Scully"]' && has 'changeApprovedBy: ["dana"]' && has 'approvalControl: human' && ! has 'no CM approver' && [ "$RC" -eq 0 ]; } \
  && ok "T33 human PR approver -> release + per-PR changeApprovedBy" || no "T33 human PR approver" "$OUT"

# ---------- T34 no reviewer, bot publisher, human merger -> merger is the CM approver ----------
mkfix T34; printf 'fixes #3401\n' > "$FIXROOT/T34/release-body.txt"; echo null > "$FIXROOT/T34/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T34/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T34/release-author.txt"
jq -n --arg a alice --arg m erin '{author:{login:$a},labels:[],reviews:[],body:"x",mergedBy:{login:$m}}' > "$FIXROOT/T34/pr-3401.json"
run T34 v2
{ has 'changeApprovedBy: ["@erin"]' && ! has 'no CM approver' && [ "$RC" -eq 0 ]; } \
  && ok "T34 human merger is the release CM approver" || no "T34 human merger" "$OUT"

# ---------- T35 release published by the change author -> not a valid approver -> needs-review ----------
mkfix T35; printf 'fixes #3501\n' > "$FIXROOT/T35/release-body.txt"; echo null > "$FIXROOT/T35/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T35/releases.txt"
echo 'alice' > "$FIXROOT/T35/release-author.txt"                   # same person who authored the change
mkpr T35 3501 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
run T35 v2
{ has 'assessmentStatus: needs-review' && has 'no CM approver' && [ "$RC" -eq 0 ]; } \
  && ok "T35 author-as-publisher is not an approver -> needs-review" || no "T35 author self-approval" "$OUT"

# ---------- T36 non-[bot] account whose GitHub type is Bot is NOT a CM approver (denylist fail-open fix) ----------
mkfix T36; printf 'fixes #3601\n' > "$FIXROOT/T36/release-body.txt"; echo null > "$FIXROOT/T36/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T36/releases.txt"
echo 'svc-release' > "$FIXROOT/T36/release-author.txt"             # not *[bot], not in denylist -> passes is_bot...
echo '{"type":"Bot","name":"Release Service"}' > "$FIXROOT/T36/user-svc-release.json"  # ...but GitHub type is Bot
mkpr T36 3601 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
run T36 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && ! has 'Release Service' && [ "$RC" -eq 0 ]; } \
  && ok "T36 type=Bot publisher rejected -> needs-review" || no "T36 type-check fail-open fix" "$OUT"

# ---------- T37 union: a human PR approver AND a human publisher are BOTH listed ----------
mkfix T37; printf 'fixes #3701\n' > "$FIXROOT/T37/release-body.txt"; echo null > "$FIXROOT/T37/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T37/releases.txt"
echo 'relmgr' > "$FIXROOT/T37/release-author.txt"
mkpr T37 3701 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"bob"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T37 v2
{ has 'changeApprovedBy: ["@bob", "@relmgr"]' && [ "$RC" -eq 0 ]; } \
  && ok "T37 release changeApprovedBy is the union (reviewer + publisher)" || no "T37 union" "$OUT"

# ---------- T38 multi-PR/multi-author: a reviewer who authored a SIBLING PR is excluded ----------
mkfix T38; printf 'fixes #3801 and #3802\n' > "$FIXROOT/T38/release-body.txt"; echo null > "$FIXROOT/T38/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T38/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T38/release-author.txt"
mkpr T38 3801 alice 'x' '[{"author":{"login":"bob"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"  # bob approves PR#3801
mkpr T38 3802 bob 'y' "$NOREV" "$NOLBL"                                                                                 # ...but bob authored PR#3802
run T38 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && [ "$RC" -eq 0 ]; } \
  && ok "T38 sibling-PR author excluded as release approver -> needs-review" || no "T38 multi-author exclusion" "$OUT"

# ---------- T39 MIX: human + bot both APPROVE one PR -> approvalControl human, changeApprovedBy = human ----------
mkfix T39; printf 'fixes #3901\n' > "$FIXROOT/T39/release-body.txt"; echo null > "$FIXROOT/T39/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T39/releases.txt"
mkpr T39 3901 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"MysticatBot"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"carol"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T39 v2
{ has 'approvalControl: human' && has 'changeApprovedBy: ["carol"]' && [ "$RC" -eq 0 ]; } \
  && ok "T39 human+bot approve -> human wins, changeApprovedBy=[carol]" || no "T39 mix" "$OUT"

# ---------- T40 no explicit approval, but a non-author human REVIEWED without objecting (COMMENTED) ----------
# CM no-objection approval policy: a review without a change-request is approval. With no approver/merger/human-publisher, the
# commenter is the fallback CM approver of record (name resolved). Release must NOT be needs-review.
mkfix T40; printf 'fixes #4001\n' > "$FIXROOT/T40/release-body.txt"; echo null > "$FIXROOT/T40/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T40/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T40/release-author.txt"       # bot publisher -> no explicit approver/merger/publisher
echo 'Fox Mulder' > "$FIXROOT/T40/user-mulder.txt"
mkpr T40 4001 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"mulder"},"state":"COMMENTED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T40 v2
{ has 'changeApprovedBy: ["Fox Mulder"]' && ! has 'no CM approver' && ! has 'assessmentStatus: needs-review' && [ "$RC" -eq 0 ]; } \
  && ok "T40 reviewed-without-objection is the fallback CM approver" || no "T40 commenter fallback" "$OUT"

# ---------- T41 a reviewer who REQUESTED CHANGES (rejection) is never a fallback approver ----------
mkfix T41; printf 'fixes #4101\n' > "$FIXROOT/T41/release-body.txt"; echo null > "$FIXROOT/T41/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T41/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T41/release-author.txt"
mkpr T41 4101 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"mulder"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T41 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && has 'no CM approver' && ! has '@mulder' && [ "$RC" -eq 0 ]; } \
  && ok "T41 changes-requested (rejection) is not a fallback approver -> needs-review" || no "T41 rejection excluded" "$OUT"

# ---------- T42 an explicit approver is present -> the commenter is NOT added (fallback only) ----------
mkfix T42; printf 'fixes #4201\n' > "$FIXROOT/T42/release-body.txt"; echo null > "$FIXROOT/T42/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T42/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T42/release-author.txt"
mkpr T42 4201 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"bob"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"dave"},"state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T42 v2
{ has 'changeApprovedBy: ["@bob"]' && ! has 'dave' && [ "$RC" -eq 0 ]; } \
  && ok "T42 explicit approver present -> commenter not added (fallback only)" || no "T42 fallback-only" "$OUT"

# ---------- T43 changes-requested THEN commented (same reviewer) -> unresolved rejection, NOT an approver ----------
# A later COMMENTED review does not clear an outstanding CHANGES_REQUESTED, so this reviewer must not
# be flipped into the CM approver (SoD fail: a rejecter recorded as sign-off).
mkfix T43; printf 'fixes #4301\n' > "$FIXROOT/T43/release-body.txt"; echo null > "$FIXROOT/T43/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T43/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T43/release-author.txt"
mkpr T43 4301 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"mulder"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"mulder"},"state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T43 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && has 'no CM approver' && ! has '@mulder' && [ "$RC" -eq 0 ]; } \
  && ok "T43 changes-requested-then-commented (unresolved rejection) is NOT an approver" || no "T43 rejecter-then-comment" "$OUT"

# ---------- T44 one reviewer rejects, a DIFFERENT one gives a no-objection review -> commenter approves ----------
mkfix T44; printf 'fixes #4401\n' > "$FIXROOT/T44/release-body.txt"; echo null > "$FIXROOT/T44/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T44/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T44/release-author.txt"
mkpr T44 4401 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"eve"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"mulder"},"state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T44 v2
{ has 'changeApprovedBy: ["@mulder"]' && ! has 'assessmentStatus: needs-review' && ! has 'eve' && [ "$RC" -eq 0 ]; } \
  && ok "T44 rejecter does not veto a different reviewer's no-objection (@login fallback)" || no "T44 mixed reviewers" "$OUT"

# ---------- T45 a COMMENTED reviewer whose GitHub type is Bot is rejected on the tier-4 path ----------
mkfix T45; printf 'fixes #4501\n' > "$FIXROOT/T45/release-body.txt"; echo null > "$FIXROOT/T45/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T45/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T45/release-author.txt"
echo '{"type":"Bot","name":"Comment Bot"}' > "$FIXROOT/T45/user-svc-commenter.json"   # not *[bot], not denylisted, but type Bot
mkpr T45 4501 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"svc-commenter"},"state":"COMMENTED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
run T45 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && ! has 'Comment Bot' && [ "$RC" -eq 0 ]; } \
  && ok "T45 type=Bot commenter dropped by the tier-4 type-check -> needs-review" || no "T45 bot commenter" "$OUT"

# ---------- T46 commenters union across multiple PRs (tier-4) ----------
mkfix T46; printf 'fixes #4601 and #4602\n' > "$FIXROOT/T46/release-body.txt"; echo null > "$FIXROOT/T46/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T46/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T46/release-author.txt"
echo 'Fox Mulder' > "$FIXROOT/T46/user-mulder.txt"; echo 'Dana Scully' > "$FIXROOT/T46/user-scully.txt"
mkpr T46 4601 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"mulder"},"state":"COMMENTED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"
mkpr T46 4602 bob "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"scully"},"state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T46 v2
{ has 'changeApprovedBy: ["Fox Mulder", "Dana Scully"]' && ! has 'assessmentStatus: needs-review' && [ "$RC" -eq 0 ]; } \
  && ok "T46 tier-4 commenters union across PRs" || no "T46 multi-PR commenter union" "$OUT"

# ---------- T47 unresolvable/empty profile lookup is dropped (fail-CLOSED type check) ----------
mkfix T47; printf 'fixes #4701\n' > "$FIXROOT/T47/release-body.txt"; echo null > "$FIXROOT/T47/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T47/releases.txt"
echo 'ghost' > "$FIXROOT/T47/release-author.txt"      # publisher, not a known bot -> passes is_bot...
echo '{}' > "$FIXROOT/T47/user-ghost.json"            # ...but the profile lookup yields no type (failed/garbled)
mkpr T47 4701 alice "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"
run T47 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && ! has '@ghost' && [ "$RC" -eq 0 ]; } \
  && ok "T47 empty/unresolvable profile dropped (fail-closed) -> needs-review" || no "T47 type fail-closed" "$OUT"

# ---------- T48 approve THEN comment: the approval stands (verdict-aware, not demoted to fallback) ----------
mkfix T48; printf 'fixes #4801\n' > "$FIXROOT/T48/release-body.txt"; echo null > "$FIXROOT/T48/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T48/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T48/release-author.txt"
mkpr T48 4801 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"bob"},"state":"APPROVED","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"bob"},"state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z"}]' "$NOLBL"
run T48 v2
{ has 'approvalControl: human' && has 'independentlyApproved: true' && has 'changeApprovedBy: ["@bob"]' && [ "$RC" -eq 0 ]; } \
  && ok "T48 approve-then-comment keeps the approval (verdict-aware)" || no "T48 approve-then-comment" "$OUT"

# ---------- T49 a commenter who authored a SIBLING PR in the release is excluded ----------
mkfix T49; printf 'fixes #4901 and #4902\n' > "$FIXROOT/T49/release-body.txt"; echo null > "$FIXROOT/T49/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T49/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T49/release-author.txt"
mkpr T49 4901 alice "$(blk 'impact: unnoticeable
risk: minor')" '[{"author":{"login":"bob"},"state":"COMMENTED","submittedAt":"2026-01-01T00:00:00Z"}]' "$NOLBL"   # bob comments on #4901
mkpr T49 4902 bob "$(blk 'impact: unnoticeable
risk: minor')" "$NOREV" "$NOLBL"                                                                                # ...but bob authored #4902
run T49 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && [ "$RC" -eq 0 ]; } \
  && ok "T49 commenter who authored a sibling PR is excluded -> needs-review" || no "T49 commenter sibling-author" "$OUT"

# ---------- T50 an assigned/requested reviewer with NO activity does NOT count (we can't tell they looked) ----------
# reviewRequests is present but must be IGNORED — a review request is not evidence the assignee looked.
mkfix T50; printf 'fixes #5001\n' > "$FIXROOT/T50/release-body.txt"; echo null > "$FIXROOT/T50/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T50/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T50/release-author.txt"
jq -n --arg a alice '{author:{login:$a},labels:[],reviews:[],mergedBy:null,comments:[],body:"## Change Management\n\n```yaml\ncm-assessment: v1\nimpact: unnoticeable\nrisk: minor\n```\n",reviewRequests:[{"__typename":"User",login:"skinner"}]}' > "$FIXROOT/T50/pr-5001.json"
run T50 v2
{ has 'assessmentStatus: needs-review' && has 'changeApprovedBy: []' && has 'no second pair of eyes' && ! has 'skinner' && [ "$RC" -eq 0 ]; } \
  && ok "T50 assigned reviewer with no activity does NOT count -> needs-review" || no "T50 assigned-no-activity" "$OUT"

# ---------- T51 a PR conversation comment (issue comment, no formal review) is engagement -> no-objection approver ----------
mkfix T51; printf 'fixes #5101\n' > "$FIXROOT/T51/release-body.txt"; echo null > "$FIXROOT/T51/published.txt"; printf 'v2\nv1\n' > "$FIXROOT/T51/releases.txt"
echo 'github-actions[bot]' > "$FIXROOT/T51/release-author.txt"; echo 'Dana Scully' > "$FIXROOT/T51/user-scully.txt"
jq -n --arg a alice '{author:{login:$a},labels:[],reviews:[],mergedBy:null,comments:[{author:{login:"scully"}}],body:"## Change Management\n\n```yaml\ncm-assessment: v1\nimpact: unnoticeable\nrisk: minor\n```\n"}' > "$FIXROOT/T51/pr-5101.json"
run T51 v2
{ has 'changeApprovedBy: ["Dana Scully"]' && ! has 'assessmentStatus: needs-review' && [ "$RC" -eq 0 ]; } \
  && ok "T51 PR conversation comment is engagement -> no-objection approver" || no "T51 issue-commenter" "$OUT"

# ---------- YAML validity on the core happy-path blocks ----------
run T1 v2;  { yaml_ok; } && ok "YAML valid (T1)" || no "YAML valid (T1)" "$OUT"
run T7 v2;  { yaml_ok; } && ok "YAML valid (T7)" || no "YAML valid (T7)" "$OUT"
run T32 v2; { yaml_ok; } && ok "YAML valid (T32 empty changeApprovedBy)" || no "YAML valid (T32)" "$OUT"
run T40 v2; { yaml_ok; } && ok "YAML valid (T40 tier-4 commenter approver)" || no "YAML valid (T40)" "$OUT"
run T51 v2; { yaml_ok; } && ok "YAML valid (T51 conversation-comment approver)" || no "YAML valid (T51)" "$OUT"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
