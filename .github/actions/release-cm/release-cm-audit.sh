#!/usr/bin/env bash
# Audit / backfill Change Management blocks on a repo's PRODUCTION releases since a date.
#
# Usage: release-cm-audit.sh <since-YYYY-MM-DD> <report|suggest|fix>
#   report   list production releases since <date> that have NO cm-attributes block
#   suggest  report + show the block release-cm.sh WOULD write (or the failure/needs-review),
#            without modifying anything
#   fix      report + actually write the block to each release missing one (idempotent)
#
# Env: REPO (default $GITHUB_REPOSITORY); GH_TOKEN (fix needs contents:write, all need
#      pull-requests:read); SNOW_YML (passed through to release-cm.sh).
# Reuses release-cm.sh in the same directory as the single source of the block.
set -euo pipefail

SINCE="${1:?usage: release-cm-audit.sh <since-YYYY-MM-DD> <report|suggest|fix>}"
MODE="${2:?usage: release-cm-audit.sh <since-YYYY-MM-DD> <report|suggest|fix>}"
REPO="${REPO:-${GITHUB_REPOSITORY:?REPO or GITHUB_REPOSITORY required}}"
case "$MODE" in report|suggest|fix) ;; *) echo "::error::mode must be report|suggest|fix (got '$MODE')" >&2; exit 2;; esac
printf '%s' "$SINCE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { echo "::error::since must be YYYY-MM-DD (got '$SINCE')" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
RELEASE_CM="$HERE/release-cm.sh"
[ -f "$RELEASE_CM" ] || { echo "::error::release-cm.sh not found next to the audit script" >&2; exit 2; }

MARKER='^[[:space:]]*cm-attributes: v1[[:space:]]*$'

# Production releases (non-draft, non-prerelease) published on/after SINCE, oldest first.
releases=$(gh release list -R "$REPO" -L 1000 --json tagName,publishedAt,isDraft,isPrerelease 2>/dev/null \
  | jq -r --arg s "$SINCE" '
      [ .[] | select(.isDraft==false and .isPrerelease==false and .publishedAt!=null and (.publishedAt[0:10] >= $s)) ]
      | sort_by(.publishedAt) | .[] | "\(.tagName)\t\(.publishedAt)"') \
  || { echo "::error::cannot list releases for $REPO (check GH_TOKEN / repo access)" >&2; exit 1; }

# Optional artifact persistence for review / sharing with stakeholders (OUT_DIR=<dir>):
# a manifest.md status table + per-release .cm.yaml block files.
OUT_DIR="${OUT_DIR:-}"
if [ -n "$OUT_DIR" ]; then
  mkdir -p "$OUT_DIR"
  MANIFEST="$OUT_DIR/manifest.md"
  { printf '# release-cm-audit — %s — since %s — mode %s\n\n' "$REPO" "$SINCE" "$MODE"
    printf '| release | date | status |\n|---|---|---|\n'; } > "$MANIFEST"
fi
mrow()      { [ -n "$OUT_DIR" ] || return 0; printf '| %s | %s | %s |\n' "$1" "$2" "$3" >> "$MANIFEST"; }
writeblock(){ [ -n "$OUT_DIR" ] || return 0; printf '%s\n' "$2" | awk '/```yaml/{f=1;next} f&&/^```/{exit} f{print}' > "$OUT_DIR/$1.cm.yaml"; }

total=0; covered=0; gap=0; suggested=0; needsreview=0; fixed=0; failed=0
echo "== release-cm-audit  repo=$REPO  since=$SINCE  mode=$MODE =="

while IFS=$'\t' read -r tag published; do
  [ -n "$tag" ] || continue
  total=$((total + 1))
  day=${published%%T*}
  body=$(gh release view "$tag" -R "$REPO" --json body -q .body 2>/dev/null || true)
  if printf '%s\n' "$body" | grep -qE "$MARKER"; then
    covered=$((covered + 1)); mrow "$tag" "$day" "covered"; continue
  fi
  gap=$((gap + 1))
  case "$MODE" in
    report)
      echo "GAP      $tag  $day  — no CM block"; mrow "$tag" "$day" "GAP — no CM block"
      ;;
    suggest)
      if out=$(DRY_RUN=1 REPO="$REPO" bash "$RELEASE_CM" "$tag" 2>&1); then
        st=$(printf '%s\n' "$out" | sed -nE 's/^assessmentStatus:[[:space:]]*([a-z-]+).*/\1/p' | head -1)
        echo "SUGGEST  $tag  $day  assessmentStatus=${st:-?}"
        printf '%s\n' "$out" | awk '/```yaml/{f=1;print "    "$0;next} f&&/^```/{print "    "$0;exit} f{print "    "$0}'
        suggested=$((suggested + 1)); [ "$st" = needs-review ] && needsreview=$((needsreview + 1))
        mrow "$tag" "$day" "suggested (${st:-?})"; writeblock "$tag" "$out"
      else
        echo "FAILED   $tag  $day  — $(printf '%s\n' "$out" | grep -m1 '::error::' | sed 's/.*::error::release-cm: //')"
        failed=$((failed + 1)); mrow "$tag" "$day" "FAILED"
      fi
      ;;
    fix)
      if out=$(REPO="$REPO" bash "$RELEASE_CM" "$tag" 2>&1); then
        st=$(printf '%s\n' "$out" | sed -nE 's/.*status=([a-z-]+).*/\1/p' | head -1)
        echo "FIXED    $tag  $day  ${st:+assessmentStatus=$st}"
        fixed=$((fixed + 1)); [ "$st" = needs-review ] && needsreview=$((needsreview + 1))
        mrow "$tag" "$day" "fixed (${st:-?})"
      else
        echo "FAILED   $tag  $day  — $(printf '%s\n' "$out" | grep -m1 '::error::' | sed 's/.*::error::release-cm: //')"
        failed=$((failed + 1)); mrow "$tag" "$day" "FAILED"
      fi
      ;;
  esac
done <<<"$releases"

echo "-- ${total} production release(s) since ${SINCE}: ${covered} already covered, ${gap} missing a CM block --"
case "$MODE" in
  suggest) echo "-- suggested ${suggested} (of which ${needsreview} need review), ${failed} could not be generated --";;
  fix)     echo "-- fixed ${fixed} (of which ${needsreview} need review), ${failed} could not be generated --";;
esac
[ -n "$OUT_DIR" ] && echo "-- artifacts written to ${OUT_DIR} --"
# fix mode signals a non-zero exit if any release could not be backfilled, so CI shows red.
[ "$MODE" = fix ] && [ "$failed" -gt 0 ] && exit 1
exit 0
