#!/usr/bin/env bash
# Build a navigable Markdown report tree for a CM-audit run from its data files.
#
# One run = one folder. Layout (data written by the audit; md written by THIS tool):
#   <run>/README.md                                  session index  -> each repo
#   <run>/<owner__repo>/repo.yaml                    data: repo: owner/name  (+ optional host:)
#   <run>/<owner__repo>/repo.md                      repo index     -> each release
#   <run>/<owner__repo>/<tag-safe>/release.yaml      data: tag, changeType, impact, risk, assessmentStatus, coverage
#   <run>/<owner__repo>/<tag-safe>/release.md        release aggregate -> each PR
#   <run>/<owner__repo>/<tag-safe>/pr-<n>.yaml       data: pr, changeType, impact, risk, rationale (title optional)
#   <run>/<owner__repo>/<tag-safe>/pr-<n>.md         per-PR + GitHub link
#
# Every .md links to GitHub, and every higher-order .md lists/links its children.
# Usage: cmr-report.sh <run-dir> [--mode M] [--since S] [--title T]
set -euo pipefail

RUN="${1:?usage: cmr-report.sh <run-dir> [--mode M --since S --title T]}"; shift || true
MODE=""; SINCE=""; TITLE="Change Management audit"
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="${2:-}"; shift 2;; --since) SINCE="${2:-}"; shift 2;; --title) TITLE="${2:-}"; shift 2;; *) shift;;
esac; done
[ -d "$RUN" ] || { echo "::error::cmr-report: no such run dir: $RUN" >&2; exit 1; }

# Read one scalar for key $2 from yaml file $1. Trims whitespace; strips a *balanced*
# surrounding quote pair (so a value merely ending in a quote is preserved); for an
# unquoted value, drops a trailing ` # comment` — matching the release-cm.sh / cm-assess-pr.sh
# parsers so the same data file renders and decorates identically.
yget(){
  local raw val
  raw=$({ grep -iE "^[[:space:]]*$2:" "$1" 2>/dev/null || true; } | head -1)
  val=$(printf '%s' "${raw#*:}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  case "$val" in
    '"'*'"') val=${val#\"}; val=${val%\"} ;;
    \'*\')   val=${val#\'}; val=${val%\'} ;;
    *)       val=$(printf '%s' "$val" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//') ;;
  esac
  printf '%s' "$val"
}
baseurl(){ case "$1" in git.corp.adobe.com) echo "https://git.corp.adobe.com";; *) echo "https://github.com";; esac; }
# Percent-encode a value for a URL path segment: allowlist the RFC-3986 unreserved set and
# encode every other byte, so no tag char (space, ), |, backtick, <, >, …) can break the link.
urlenc(){
  local s="$1" out="" i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in [A-Za-z0-9._~-]) out+="$c";; *) out+=$(printf '%%%02X' "'$c");; esac
  done
  printf '%s' "$out"
}
# Backslash-escape the Markdown-active chars so an untrusted value used as link TEXT or a table
# cell cannot forge a link or break the table. Backslash first, so we don't double-escape.
mdesc(){
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\`/\\\`}; s=${s//\|/\\|}
  s=${s//\[/\\[}; s=${s//\]/\\]}; s=${s//(/\\(}; s=${s//)/\\)}; s=${s//</\\<}; s=${s//>/\\>}
  printf '%s' "$s"
}

nrepos=0; nrel=0; npr=0
for repodir in "$RUN"/*/; do
  [ -f "${repodir}repo.yaml" ] || continue
  nrepos=$((nrepos+1))
  repo=$(yget "${repodir}repo.yaml" repo); host=$(yget "${repodir}repo.yaml" host); base=$(baseurl "${host:-github.com}")

  for reldir in "${repodir}"*/; do
    [ -f "${reldir}release.yaml" ] || continue
    nrel=$((nrel+1))
    tag=$(yget "${reldir}release.yaml" tag); tdisp=$(mdesc "$tag")  # tdisp = link/table-safe display form
    rct=$(yget "${reldir}release.yaml" changeType); rim=$(yget "${reldir}release.yaml" impact); rrk=$(yget "${reldir}release.yaml" risk)
    rst=$(yget "${reldir}release.yaml" assessmentStatus); rcov=$(yget "${reldir}release.yaml" coverage)
    [ -n "$rcov" ] || rcov=$(yget "${reldir}release.yaml" assessedCoverage)  # accept either field name
    relurl="$base/$repo/releases/tag/$(urlenc "$tag")"

    for prf in "${reldir}"pr-*.yaml; do
      [ -e "$prf" ] || continue
      npr=$((npr+1))
      n=$(basename "$prf" .yaml); n=${n#pr-}   # PR number is the filename, the authoritative link target
      ct=$(yget "$prf" changeType); im=$(yget "$prf" impact); rk=$(yget "$prf" risk)
      title=$(yget "$prf" title); rat=$(yget "$prf" rationale)
      { echo "# PR #$n — $repo"; echo
        [ -n "$title" ] && echo "> $title" && echo
        echo "- GitHub PR: [$repo#$n]($base/$repo/pull/$n)"
        echo "- Release: [$tdisp](./release.md) · [on GitHub]($relurl)"
        echo "- Repo: [repo.md](../repo.md)"
        echo; echo "| changeType | impact | risk |"; echo "|---|---|---|"; echo "| $ct | $im | $rk |"
        echo; echo "$rat"
      } > "${prf%.yaml}.md"
    done

    { echo "# Release $tdisp — $repo"; echo
      echo "- GitHub release: [$tdisp]($relurl)"
      echo "- Repo: [repo.md](../repo.md) · Session: [README.md](../../README.md)"
      echo; echo "## Change Management (aggregate)"; echo '```yaml'
      echo "changeType: ${rct}"; echo "impact: ${rim}"; echo "risk: ${rrk}"
      echo "assessmentStatus: ${rst}"; echo "assessedCoverage: \"${rcov}\""; echo '```'
      echo; echo "## PRs in this release"
      for prf in "${reldir}"pr-*.yaml; do [ -e "$prf" ] || continue
        n=$(basename "$prf" .yaml); n=${n#pr-}; im=$(yget "$prf" impact); rk=$(yget "$prf" risk)
        echo "- [PR #$n](pr-$n.md) — ${im}/${rk} · [GitHub]($base/$repo/pull/$n)"
      done
    } > "${reldir}release.md"
  done

  { echo "# $repo — CM audit"; echo
    echo "- GitHub: [$repo]($base/$repo)"; echo "- Session: [README.md](../README.md)"
    echo; echo "## Releases"; echo "| release | changeType | impact | risk | status |"; echo "|---|---|---|---|---|"
    for reldir in "${repodir}"*/; do [ -f "${reldir}release.yaml" ] || continue
      tag=$(yget "${reldir}release.yaml" tag); ts=$(basename "$reldir")
      printf "| [%s](%s/release.md) | %s | %s | %s | %s |\n" "$(mdesc "$tag")" "$ts" \
        "$(yget "${reldir}release.yaml" changeType)" "$(yget "${reldir}release.yaml" impact)" \
        "$(yget "${reldir}release.yaml" risk)" "$(yget "${reldir}release.yaml" assessmentStatus)"
    done
  } > "${repodir}repo.md"
done

{ echo "# $TITLE"; echo
  [ -n "$MODE" ]  && echo "- mode: **$MODE**"
  [ -n "$SINCE" ] && echo "- since: **$SINCE**"
  echo "- generated: $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "- scope: **$nrepos** repos, **$nrel** releases, **$npr** PRs"
  echo; echo "## Repos"; echo "| repo | releases |"; echo "|---|--:|"
  for repodir in "$RUN"/*/; do [ -f "${repodir}repo.yaml" ] || continue
    repo=$(yget "${repodir}repo.yaml" repo); od=$(basename "$repodir")
    # count only releases at the rendered depth, so this matches repo.md (not deeper strays)
    rn=$({ find "$repodir" -mindepth 2 -maxdepth 2 -name release.yaml 2>/dev/null || true; } | wc -l | tr -d " ")
    printf "| [%s](%s/repo.md) | %s |\n" "$repo" "$od" "$rn"
  done
} > "$RUN/README.md"

# Guard the silent-coverage-hole failure mode: a release.yaml nested below the flat layout
# (e.g. a tag containing '/' mirrored into folders) is not rendered — warn loudly, don't drop quietly.
deep=$({ find "$RUN" -mindepth 4 -name release.yaml 2>/dev/null || true; } | wc -l | tr -d " ")
[ "${deep:-0}" -gt 0 ] && echo "::warning::cmr-report: $deep release folder(s) nested below the flat layout were NOT rendered (non-flat tag folder?)" >&2 || true

echo "cmr-report: wrote md tree under $RUN ($nrepos repos, $nrel releases, $npr PRs)"
