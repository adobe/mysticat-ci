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

yget(){ { grep -iE "^[[:space:]]*$2:" "$1" 2>/dev/null || true; } | head -1 | sed -E "s/^[^:]*:[[:space:]]*//; s/^[\"']//; s/[\"']$//"; }
baseurl(){ case "$1" in git.corp.adobe.com) echo "https://git.corp.adobe.com";; *) echo "https://github.com";; esac; }

nrepos=0; nrel=0; npr=0
for repodir in "$RUN"/*/; do
  [ -f "${repodir}repo.yaml" ] || continue
  nrepos=$((nrepos+1))
  repo=$(yget "${repodir}repo.yaml" repo); host=$(yget "${repodir}repo.yaml" host); base=$(baseurl "${host:-github.com}")

  for reldir in "${repodir}"*/; do
    [ -f "${reldir}release.yaml" ] || continue
    nrel=$((nrel+1))
    tag=$(yget "${reldir}release.yaml" tag)
    rct=$(yget "${reldir}release.yaml" changeType); rim=$(yget "${reldir}release.yaml" impact); rrk=$(yget "${reldir}release.yaml" risk)
    rst=$(yget "${reldir}release.yaml" assessmentStatus); rcov=$(yget "${reldir}release.yaml" coverage)
    relurl="$base/$repo/releases/tag/$tag"

    for prf in "${reldir}"pr-*.yaml; do
      [ -e "$prf" ] || continue
      npr=$((npr+1))
      n=$(yget "$prf" pr); ct=$(yget "$prf" changeType); im=$(yget "$prf" impact); rk=$(yget "$prf" risk)
      title=$(yget "$prf" title); rat=$(yget "$prf" rationale)
      { echo "# PR #$n — $repo"; echo
        [ -n "$title" ] && echo "> $title" && echo
        echo "- GitHub PR: [$repo#$n]($base/$repo/pull/$n)"
        echo "- Release: [$tag](./release.md) · [on GitHub]($relurl)"
        echo "- Repo: [repo.md](../repo.md)"
        echo; echo "| changeType | impact | risk |"; echo "|---|---|---|"; echo "| $ct | $im | $rk |"
        echo; echo "$rat"
      } > "${prf%.yaml}.md"
    done

    { echo "# Release $tag — $repo"; echo
      echo "- GitHub release: [$tag]($relurl)"
      echo "- Repo: [repo.md](../repo.md) · Session: [README.md](../../README.md)"
      echo; echo "## Change Management (aggregate)"; echo '```yaml'
      echo "changeType: ${rct}"; echo "impact: ${rim}"; echo "risk: ${rrk}"
      echo "assessmentStatus: ${rst}"; echo "assessedCoverage: \"${rcov}\""; echo '```'
      echo; echo "## PRs in this release"
      for prf in "${reldir}"pr-*.yaml; do [ -e "$prf" ] || continue
        n=$(yget "$prf" pr); im=$(yget "$prf" impact); rk=$(yget "$prf" risk)
        echo "- [PR #$n](pr-$n.md) — ${im}/${rk} · [GitHub]($base/$repo/pull/$n)"
      done
    } > "${reldir}release.md"
  done

  { echo "# $repo — CM audit"; echo
    echo "- GitHub: [$repo]($base/$repo)"; echo "- Session: [README.md](../README.md)"
    echo; echo "## Releases"; echo "| release | changeType | impact | risk | status |"; echo "|---|---|---|---|---|"
    for reldir in "${repodir}"*/; do [ -f "${reldir}release.yaml" ] || continue
      tag=$(yget "${reldir}release.yaml" tag); ts=$(basename "$reldir")
      printf "| [%s](%s/release.md) | %s | %s | %s | %s |\n" "$tag" "$ts" \
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
    rn=$(find "$repodir" -mindepth 2 -name release.yaml 2>/dev/null | wc -l | tr -d " ")
    printf "| [%s](%s/repo.md) | %s |\n" "$repo" "$od" "$rn"
  done
} > "$RUN/README.md"

echo "cmr-report: wrote md tree under $RUN ($nrepos repos, $nrel releases, $npr PRs)"
