#!/usr/bin/env bash
# Tests for cm-assess-pr-auto.sh (CI safety-net: ensure a PR carries a cm-assessment block).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AUTO="$HERE/cm-assess-pr-auto.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$TMP/bin" "$FIX"; export FIX

cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
FIX="${FIX:?}"
if [ "$1" = "api" ] && [ "${2#users/}" != "$2" ]; then jq -n '{type:"User",name:""}'; exit 0; fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  n="$3"
  case "$*" in
    *author*) b=$(cat "$FIX/body-$n.txt" 2>/dev/null || echo ""); jq -n --arg b "$b" '{author:{login:"alice"},body:$b,reviews:[],comments:[],mergedBy:null}'; exit 0;;  # cm-assess-pr.sh full-json read
    *labels*) cat "$FIX/labels-$n.txt" 2>/dev/null || true; exit 0;;
    *body*)   cat "$FIX/body-$n.txt" 2>/dev/null || echo ""; exit 0;;
  esac
fi
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then echo edited; exit 0; fi
exit 0
SH
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"

pass=0; fail=0
ok(){ printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL  %s\n' "$1"; printf '%s\n' "$2" | sed 's/^/      /'; fail=$((fail+1)); }
has(){ case "$OUT" in *"$1"*) return 0;; *) return 1;; esac; }
run(){ OUT=$( REPO=x/y DRY_RUN=1 "$@" bash "$AUTO" "$PRN" 2>&1 ); RC=$?; }

# B1 PR already has a block -> leave it, no write
printf 'body\n\n## Change Management\n\n```yaml\ncm-assessment: v1\nimpact: outage\nrisk: major\n```\n' > "$FIX/body-10.txt"
PRN=10 run
{ has 'already has a cm-assessment block' && ! has 'DRY RUN' && [ "$RC" -eq 0 ]; } \
  && ok "B1 preserves an existing block" || no "B1" "$OUT (rc=$RC)"

# B2 no block, no label -> baseline standard/unnoticeable/minor
printf 'just a plain PR body\n' > "$FIX/body-20.txt"; : > "$FIX/labels-20.txt"
PRN=20 run
{ has 'cm-assessment: v1' && has 'changeType: standard' && has 'impact: unnoticeable' && has 'risk: minor' && [ "$RC" -eq 0 ]; } \
  && ok "B2 writes baseline when unassessed" || no "B2" "$OUT (rc=$RC)"

# B3 no block, cmr:high-risk label -> escalated normal/degradation/major
printf 'plain body\n' > "$FIX/body-30.txt"; printf 'some-label\ncmr:high-risk\n' > "$FIX/labels-30.txt"
PRN=30 run
{ has 'cm-assessment: v1' && has 'changeType: normal' && has 'impact: degradation' && has 'risk: major' && [ "$RC" -eq 0 ]; } \
  && ok "B3 escalates on cmr:high-risk label" || no "B3" "$OUT (rc=$RC)"

# B4 an unrelated label does NOT escalate
printf 'plain body\n' > "$FIX/body-40.txt"; printf 'bug\nenhancement\n' > "$FIX/labels-40.txt"
PRN=40 run
{ has 'impact: unnoticeable' && has 'risk: minor' && ! has 'impact: degradation' && [ "$RC" -eq 0 ]; } \
  && ok "B4 unrelated label stays baseline" || no "B4" "$OUT (rc=$RC)"

echo
echo "-------- $pass passed, $fail failed --------"
[ "$fail" -eq 0 ]
