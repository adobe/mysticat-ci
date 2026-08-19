#!/usr/bin/env bash
# Tests for cm-assess-pr.sh (writes a cm-assessment block into a PR description).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/cm-assess-pr.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$TMP/bin" "$FIX"; export FIX

cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
FIX="${FIX:?}"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then cat "$FIX/body-$3.txt" 2>/dev/null || echo ""; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then echo edited; exit 0; fi
exit 0
SH
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; printf '%s\n' "$2" | sed 's/^/      /'; fail=$((fail+1)); }
has(){ case "$OUT" in *"$1"*) return 0;; *) return 1;; esac; }
run(){ OUT=$( REPO=x/y "$@" bash "$SCRIPT" "$PRN" "$FLD" 2>&1 ); RC=$?; }

printf 'changeType: normal\nimpact: degradation\nrisk: major\nrationale: "adds a migration"\n' > "$TMP/f.good"
printf 'impact: bogus\nrisk: major\n' > "$TMP/f.badimpact"
printf 'changeType: normal\nimpact: degradation\n' > "$TMP/f.norisk"

# A1 no existing block -> DRY shows block
printf 'plain PR body\n' > "$FIX/body-10.txt"
PRN=10 FLD="$TMP/f.good" DRY_RUN=1 run
{ has 'cm-assessment: v1' && has 'impact: degradation' && has 'risk: major' && [ "$RC" -eq 0 ]; } && ok "A1 appends block (dry)" || no "A1" "$OUT"

# A2 existing block -> skip
printf 'body\n\n## Change Management\n\n```yaml\ncm-assessment: v1\nimpact: minor\n```\n' > "$FIX/body-11.txt"
PRN=11 FLD="$TMP/f.good" DRY_RUN=1 run
{ has 'already has a cm-assessment block' && ! has '=== DRY RUN' && [ "$RC" -eq 0 ]; } && ok "A2 skips existing" || no "A2" "$OUT"

# A3 invalid impact -> exit 2
printf 'x\n' > "$FIX/body-12.txt"
PRN=12 FLD="$TMP/f.badimpact" DRY_RUN=1 run
{ has 'valid impact' && [ "$RC" -eq 2 ]; } && ok "A3 rejects invalid impact" || no "A3" "$OUT (rc=$RC)"

# A4 missing risk -> exit 2
PRN=12 FLD="$TMP/f.norisk" DRY_RUN=1 run
{ has 'valid risk' && [ "$RC" -eq 2 ]; } && ok "A4 rejects missing risk" || no "A4" "$OUT (rc=$RC)"

# A5 FORCE over existing -> appends
PRN=11 FLD="$TMP/f.good" DRY_RUN=1 FORCE=1 run
{ has '=== DRY RUN' && has 'cm-assessment: v1' && [ "$RC" -eq 0 ]; } && ok "A5 FORCE appends over existing" || no "A5" "$OUT"

# A6 non-DRY writes
PRN=10 FLD="$TMP/f.good" run
{ has 'wrote cm-assessment to PR #10' && [ "$RC" -eq 0 ]; } && ok "A6 non-dry writes" || no "A6" "$OUT"

# A7 unified pr-<n>.yaml (report-only pr/title keys) -> dropped from the embedded block
printf 'pr: 10\ntitle: some PR title\nchangeType: normal\nimpact: degradation\nrisk: major\nrationale: "x"\n' > "$TMP/f.unified"
PRN=10 FLD="$TMP/f.unified" DRY_RUN=1 run
{ has 'impact: degradation' && has 'risk: major' && ! has 'pr: 10' && ! has 'title: some PR title' && [ "$RC" -eq 0 ]; } \
  && ok "A7 drops report-only pr/title keys" || no "A7" "$OUT"

# A8 multi-line rationale trying to inject a second fenced block -> only its first line is read,
#    the injected fence/markdown never lands in the PR body
printf 'changeType: standard\nimpact: no-impact\nrisk: minor\nrationale: "line one\n```\nextra markdown here\n"\n' > "$TMP/f.fence"
PRN=10 FLD="$TMP/f.fence" DRY_RUN=1 run
count=$(printf '%s\n' "$OUT" | grep -c 'cm-assessment: v1')
{ [ "$count" -eq 1 ] && ! has 'extra markdown here' && [ "$RC" -eq 0 ]; } \
  && ok "A8 neutralizes fenced-block injection in rationale" || no "A8" "$OUT (count=$count rc=$RC)"

# A9 duplicate gating key -> rejected as ambiguous
printf 'changeType: standard\nimpact: no-impact\nrisk: minor\nimpact: outage\n' > "$TMP/f.dupimpact"
PRN=10 FLD="$TMP/f.dupimpact" DRY_RUN=1 run
{ has 'ambiguous' && [ "$RC" -eq 2 ]; } && ok "A9 rejects duplicate impact" || no "A9" "$OUT (rc=$RC)"

# A10 multi-line title injecting impact/risk continuation lines -> rejected (impact appears twice)
printf 'pr: 42\ntitle: "harmless\nimpact: no-impact\nrisk: minor"\nchangeType: normal\nimpact: outage\nrisk: major\n' > "$TMP/f.titleinject"
PRN=10 FLD="$TMP/f.titleinject" DRY_RUN=1 run
{ has 'ambiguous' && [ "$RC" -eq 2 ]; } && ok "A10 rejects multi-line title injection" || no "A10" "$OUT (rc=$RC)"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
