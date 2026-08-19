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

# Optional artifact persistence (RUN=<dir>; OUT_DIR accepted as a legacy alias). The audit
# COLLECTS facts into the SAME nested layout cmr-report.sh renders, so the whole toolchain
# shares one scheme: <RUN>/<owner>__<repo>/{repo.yaml, <tag-safe>/release.yaml, <tag-safe>/pr-<n>.yaml}.
# Render the navigable md tree afterwards with:  cmr-report.sh <RUN> --mode <mode> --since <since>
RUN="${RUN:-${OUT_DIR:-}}"
owner_repo=${REPO/\//__}
repodir="$RUN/$owner_repo"
if [ -n "$RUN" ]; then
  mkdir -p "$repodir"
  [ -f "$repodir/repo.yaml" ] || printf 'repo: %s\nhost: %s\n' "$REPO" "${GH_HOST:-github.com}" > "$repodir/repo.yaml"
fi
tagsafe(){ printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g'; }   # enforce a flat, path-safe folder name

# Minimal release.yaml (report mode + fallbacks): tag + a coverage/status label.
write_status(){
  [ -n "$RUN" ] || return 0
  local d; d="$repodir/$(tagsafe "$1")"; mkdir -p "$d"
  printf 'tag: %s\nassessmentStatus: %s\n' "$1" "$2" > "$d/release.yaml"
}

# release.yaml (+ per-PR pr-<n>.yaml) parsed from a release-cm DRY block ($2 = its full output).
# A pr-<n>.yaml the agent already authored (richer: rationale/title) is kept, not overwritten.
write_release(){
  [ -n "$RUN" ] || return 0
  local d blk ct im rk st cov
  d="$repodir/$(tagsafe "$1")"; mkdir -p "$d"
  blk=$(printf '%s\n' "$2" | awk '/```yaml/{f=1;next} f&&/^```/{exit} f{print}')
  ct=$(printf  '%s\n' "$blk" | sed -nE 's/^changeType:[[:space:]]*([a-z]+).*/\1/p'  | head -1)
  im=$(printf  '%s\n' "$blk" | sed -nE 's/^impact:[[:space:]]*([a-z-]+).*/\1/p'      | head -1)
  rk=$(printf  '%s\n' "$blk" | sed -nE 's/^risk:[[:space:]]*([a-z]+).*/\1/p'         | head -1)
  st=$(printf  '%s\n' "$blk" | sed -nE 's/^assessmentStatus:[[:space:]]*([a-z-]+).*/\1/p' | head -1)
  cov=$({ printf '%s\n' "$blk" | grep -E '^assessedCoverage:' || true; } | head -1 | sed -E 's/^assessedCoverage:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"//; s/"$//')
  { printf 'tag: %s\n' "$1"
    [ -n "$ct" ]  && printf 'changeType: %s\n' "$ct"
    [ -n "$im" ]  && printf 'impact: %s\n' "$im"
    [ -n "$rk" ]  && printf 'risk: %s\n' "$rk"
    printf 'assessmentStatus: %s\n' "${st:-unassessed}"
    [ -n "$cov" ] && printf 'coverage: "%s"\n' "$cov"
  } > "$d/release.yaml"
  # per-PR rows come from the changes: list (impact/risk only; the agent enriches later)
  { printf '%s\n' "$blk" | awk '
      /^changes:/{inc=1;next} !inc{next}
      /^[[:space:]]*-[[:space:]]*pr:[[:space:]]*[0-9]+/ { if(pr!="")print pr"\t"im"\t"rk; pr=$0; sub(/.*pr:[[:space:]]*/,"",pr); sub(/[^0-9].*/,"",pr); im=""; rk=""; next }
      /^[[:space:]]*impact:/ { s=$0; sub(/^[[:space:]]*impact:[[:space:]]*/,"",s); sub(/[[:space:]#].*$/,"",s); im=s; next }
      /^[[:space:]]*risk:/   { s=$0; sub(/^[[:space:]]*risk:[[:space:]]*/,"",s);   sub(/[[:space:]#].*$/,"",s); rk=s; next }
      END{ if(pr!="")print pr"\t"im"\t"rk }' ; } | while IFS=$'\t' read -r pn pim prk; do
    [ -n "$pn" ] || continue
    f="$d/pr-$pn.yaml"
    [ -f "$f" ] && continue
    { printf 'pr: %s\n' "$pn"; [ -n "$pim" ] && printf 'impact: %s\n' "$pim"; [ -n "$prk" ] && printf 'risk: %s\n' "$prk"; } > "$f"
  done
}

total=0; covered=0; gap=0; suggested=0; needsreview=0; fixed=0; failed=0
echo "== release-cm-audit  repo=$REPO  since=$SINCE  mode=$MODE =="

while IFS=$'\t' read -r tag published; do
  [ -n "$tag" ] || continue
  total=$((total + 1))
  day=${published%%T*}
  body=$(gh release view "$tag" -R "$REPO" --json body -q .body 2>/dev/null || true)
  if printf '%s\n' "$body" | grep -qE "$MARKER"; then
    covered=$((covered + 1)); write_status "$tag" covered; continue
  fi
  gap=$((gap + 1))
  case "$MODE" in
    report)
      echo "GAP      $tag  $day  — no CM block"; write_status "$tag" gap
      ;;
    suggest)
      if out=$(DRY_RUN=1 REPO="$REPO" bash "$RELEASE_CM" "$tag" 2>&1); then
        st=$(printf '%s\n' "$out" | sed -nE 's/^assessmentStatus:[[:space:]]*([a-z-]+).*/\1/p' | head -1)
        echo "SUGGEST  $tag  $day  assessmentStatus=${st:-?}"
        printf '%s\n' "$out" | awk '/```yaml/{f=1;print "    "$0;next} f&&/^```/{print "    "$0;exit} f{print "    "$0}'
        suggested=$((suggested + 1)); [ "$st" = needs-review ] && needsreview=$((needsreview + 1))
        write_release "$tag" "$out"
      else
        echo "FAILED   $tag  $day  — $(printf '%s\n' "$out" | grep -m1 '::error::' | sed 's/.*::error::release-cm: //')"
        failed=$((failed + 1)); write_status "$tag" failed
      fi
      ;;
    fix)
      if out=$(REPO="$REPO" bash "$RELEASE_CM" "$tag" 2>&1); then
        st=$(printf '%s\n' "$out" | sed -nE 's/.*status=([a-z-]+).*/\1/p' | head -1)
        echo "FIXED    $tag  $day  ${st:+assessmentStatus=$st}"
        fixed=$((fixed + 1)); [ "$st" = needs-review ] && needsreview=$((needsreview + 1))
        # capture the block via a DRY pass so the shared data files reflect what was written
        dry=$(DRY_RUN=1 REPO="$REPO" bash "$RELEASE_CM" "$tag" 2>&1) && write_release "$tag" "$dry" || write_status "$tag" "${st:-fixed}"
      else
        echo "FAILED   $tag  $day  — $(printf '%s\n' "$out" | grep -m1 '::error::' | sed 's/.*::error::release-cm: //')"
        failed=$((failed + 1)); write_status "$tag" failed
      fi
      ;;
  esac
done <<<"$releases"

echo "-- ${total} production release(s) since ${SINCE}: ${covered} already covered, ${gap} missing a CM block --"
case "$MODE" in
  suggest) echo "-- suggested ${suggested} (of which ${needsreview} need review), ${failed} could not be generated --";;
  fix)     echo "-- fixed ${fixed} (of which ${needsreview} need review), ${failed} could not be generated --";;
esac
[ -n "$RUN" ] && echo "-- data written to ${repodir}/ — render the tree with: cmr-report.sh ${RUN} --mode ${MODE} --since ${SINCE} --"
# fix mode signals a non-zero exit if any release could not be backfilled, so CI shows red.
[ "$MODE" = fix ] && [ "$failed" -gt 0 ] && exit 1
exit 0
