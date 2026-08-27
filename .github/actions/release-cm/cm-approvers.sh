#!/usr/bin/env bash
# Shared CM change-approver logic, sourced by release-cm.sh (release changes[] + aggregate) and
# cm-assess-pr.sh (the PR's own block). One definition so the two never drift.
#
# A change's approver(s) = the non-author human(s) who ENGAGED with that pull request and did not
# object: reviewed it (an APPROVED review, or a COMMENTED review / PR conversation comment) or merged
# it. A CHANGES_REQUESTED verdict is a rejection and never qualifies (a later comment does not clear an
# outstanding change-request). Bots never count; every candidate is verified to be a real GitHub
# `User` (fail-closed — a non-User type or an unresolvable lookup is dropped). The PR's own author is
# excluded (you cannot approve your own change).
#
# Requires: bash, jq, gh. The caller owns `set -euo pipefail`; every function here is safe under it.

# Automation identities that do NOT count as a human approver. A `*[bot]` login is always automation;
# the rest are a hardcoded, known set (AI reviewers, CI, mergers) extendable via the BOT_IDENTITIES
# env (one login per line). Matched case-insensitively, whole-login.
BOT_IDENTITIES="${BOT_IDENTITIES:-}
github-actions[bot]
renovate[bot]
renovate-approve
dependabot[bot]
kodiakhq[bot]
MysticatBot
MysticatBot-Dev
mysticatbot_adobe"

is_bot() {   # $1 = login; returns 0 (true) when the login is automation, 1 when it is a human
  local l; l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$l" in *'[bot]') return 0;; esac
  printf '%s\n' "$BOT_IDENTITIES" | grep -qixF -- "$1"
}

# Per-process cache for the user-profile lookups (login -> "login\tU\t<name>" | "login\tN"), so a
# person met on several PRs of one release is queried once. The caller removes it (release-cm.sh /
# cm-assess-pr.sh EXIT trap); if unset we create one here.
: "${CM_PERSON_CACHE:=$(mktemp)}"

verify_person() {   # $1 = login; prints the display NAME and returns 0 iff a real GitHub `User`
  local lg="$1" hit uj typ nm
  hit=$(awk -F'\t' -v l="$lg" '$1==l{print; exit}' "$CM_PERSON_CACHE" 2>/dev/null || true)
  if [ -z "$hit" ]; then
    uj=$(gh api "users/$lg" 2>/dev/null || echo '{}')
    typ=$(printf '%s' "$uj" | jq -r '.type // ""' 2>/dev/null || true)
    if [ "$typ" = User ]; then
      nm=$(printf '%s' "$uj" | jq -r '.name // ""' 2>/dev/null | tr -d '\n\t' || true); case "$nm" in ""|null) nm="@$lg";; esac  # strip \n\t: keep one cache record per line
      printf '%s\tU\t%s\n' "$lg" "$nm" >>"$CM_PERSON_CACHE"; printf '%s' "$nm"; return 0
    fi
    printf '%s\tN\n' "$lg" >>"$CM_PERSON_CACHE"; return 1
  fi
  case "$(printf '%s' "$hit" | cut -f2)" in
    U) printf '%s' "$hit" | cut -f3-; return 0;;
    *) return 1;;
  esac
}

# Emit `login<TAB>display-name` for each verified, non-author, non-bot human who approved the change
# in $1 (the PR JSON from `gh pr view --json author,reviews,comments,mergedBy`). $2 = the PR author.
pr_change_approvers() {
  local pj="$1" author="$2" cands lg disp
  cands=$(printf '%s' "$pj" | jq -r --arg a "$author" '
    [.reviews[]?|select(.author.login!=null)] as $all
    | ($all|map(select(.state=="APPROVED" or .state=="CHANGES_REQUESTED"))|group_by(.author.login)|map(sort_by(.submittedAt)|last)) as $verd
    | ($verd|map(select(.state=="APPROVED"))|map(.author.login)) as $approved
    | ($verd|map(select(.state=="CHANGES_REQUESTED"))|map(.author.login)) as $rejecters
    | ($all|map(select(.state=="COMMENTED"))|map(.author.login)) as $commented
    | ([.comments[]?|.author.login // empty]) as $discussed
    | ([.mergedBy.login // empty]|map(select(.!=""))) as $merger
    | ((((($approved + $commented + $discussed + $merger)|unique) - $rejecters) - [$a]))
    | .[]' 2>/dev/null || true)
  while IFS= read -r lg; do
    [ -n "$lg" ] || continue
    if is_bot "$lg"; then continue; fi
    disp=$(verify_person "$lg") || continue
    printf '%s\t%s\n' "$lg" "$disp"
  done <<<"$cands"
}
