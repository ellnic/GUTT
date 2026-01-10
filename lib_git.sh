#!/usr/bin/env bash
# lib_git.sh - git primitives (no UI)

git_repo_root() {
  local dir="$1"
  (cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
}

git_current_branch() {
  local repo="$1"
  (cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
}

git_is_detached() {
  local repo="$1"
  local b
  b="$(git_current_branch "$repo")"
  [[ "$b" == "HEAD" || -z "$b" ]]
}

git_has_changes() {
  local repo="$1"
  (cd "$repo" && [[ -n "$(git status --porcelain 2>/dev/null)" ]])
}

git_upstream() {
  local repo="$1"
  (cd "$repo" && git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null) || true
}

git_branch_exists() {
  # Usage: git_branch_exists <repo> <branch>
  local repo="$1" branch="$2"
  (cd "$repo" && git show-ref --verify --quiet "refs/heads/$branch")
}

git_detect_main_branch() {
  # Best-effort detection of the primary branch name.
  # Prefers local branches, then origin/HEAD, then falls back to "main".
  local repo="$1"

  if git_branch_exists "$repo" "main"; then
    printf '%s' "main"; return 0
  fi
  if git_branch_exists "$repo" "master"; then
    printf '%s' "master"; return 0
  fi

  local sym
  sym="$(cd "$repo" && git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$sym" ]]; then
    # e.g. refs/remotes/origin/main -> main
    printf '%s' "${sym##*/}"
    return 0
  fi

  printf '%s' "main"
}

git_tag_exists() {
  local repo="$1" tag="$2"
  (cd "$repo" && git show-ref --verify --quiet "refs/tags/$tag")
}

validate_tag_name() {
  local tag="$1"
  [[ -n "$tag" ]] || return 1
  git check-ref-format "refs/tags/$tag" >/dev/null 2>&1
}

have_origin_remote() {
  local repo="$1"
  (cd "$repo" && git remote get-url origin >/dev/null 2>&1)
}

repo_summary() {
  local repo="$1"
  local branch upstream ahead behind dirty staged untracked stash_cnt last_commit remotes
  branch="$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$branch" == "HEAD" || -z "$branch" ]]; then branch="DETACHED"; fi

  upstream="$(git_upstream "$repo")"
  if [[ -z "$upstream" ]]; then upstream="(none)"; fi

  if [[ "$upstream" != "(none)" ]]; then
    local counts
    counts="$(cd "$repo" && git rev-list --left-right --count "$upstream"...HEAD 2>/dev/null || true)"
    behind="${counts%% *}"
    ahead="${counts##* }"
  else
    ahead="?"
    behind="?"
  fi

  dirty="$(cd "$repo" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  staged="$(cd "$repo" && git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
  untracked="$(cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
  stash_cnt="$(cd "$repo" && git stash list 2>/dev/null | wc -l | tr -d ' ')"
  last_commit="$(cd "$repo" && git log -1 --pretty=format:'%h %s (%ad)' --date=short 2>/dev/null || true)"
  remotes="$(cd "$repo" && git remote -v 2>/dev/null | awk '{print $1"  "$2}' | sort -u | head -n 6 || true)"

  cat <<EOF
Repo:      $repo
Branch:    $branch
Upstream:  $upstream
Ahead:     $ahead
Behind:    $behind

Changes:   $dirty file(s) changed
Staged:    $staged file(s) staged
Untracked: $untracked file(s) untracked
Stash:     $stash_cnt item(s)

Last:      $last_commit

Remotes:
$remotes
EOF
}

danger_preflight() {
  local repo="$1" action="$2"
  local tmp rc=0 had_e=0

  tmp="$(mktemp_gutt)"
  repo_summary "$repo" >"$tmp"

  [[ $- == *e* ]] && had_e=1
  set +e
  whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "DANGER: $action

$(cat "$tmp")

Proceed?" 22 90 3>&1 1>&2 2>&3
  rc=$?
  ((had_e)) && set -e

  rm -f "$tmp"

  # Phase 8.4: if we're about to do something risky, gently offer a known-good tag first.
  # Default behaviour stays the same (this prompt defaults to NO and can be skipped).
  if [[ $rc -eq 0 ]]; then
    offer_known_good_tag "$repo"
  fi

  return $rc
}

has_known_good_tag_at_head() {
  local repo="$1"
  (cd "$repo" && git tag --points-at HEAD "gutt/known-good-*" 2>/dev/null | head -n1 | grep -q .)
}

offer_known_good_tag() {
  local repo="$1"

  # If a known-good tag already points at HEAD, nothing to do.
  if has_known_good_tag_at_head "$repo"; then
    return 0
  fi

  if ! yesno "No known-good tag points at current HEAD.\n\nCreate one now? (Recommended)\n\nThis stays local unless you push tags." ; then
    return 0
  fi

  local ts default_tag tag note branch head msg
  ts="$(date +%Y%m%d-%H%M)"
  default_tag="gutt/known-good-$ts"

  tag="$(inputbox "Known-good tag name" "$default_tag")" || return 0
  [[ -n "$tag" ]] || return 0

  note="$(inputbox "Optional note (can be blank)" "")" || return 0

  branch="$(git_current_branch "$repo")"
  head="$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null)" || head="?"

  msg="Known-good state marked by GUTT\nBranch: $branch\nCommit: $head"
  if [[ -n "$note" ]]; then
    msg="$msg\n\nNote: $note"
  fi

  if (cd "$repo" && git tag -a "$tag" -m "$msg" >/dev/null 2>&1); then
    msgbox "Created known-good tag:\n\n$tag"
  else
    msgbox "Failed to create known-good tag:\n\n$tag\n\n(If the tag already exists, choose a different name.)"
  fi
}

offer_backup_tag() {
  local repo="$1"
  if [[ "$(cfg_get offer_backup_tag_before_danger 1)" != "1" ]]; then
    return 0
  fi
  local ts tag
  ts="$(date +%Y%m%d-%H%M%S)"
  tag="gutt/backup-$ts"
  if yesno "Create a local safety tag before proceeding?\n\nTag: $tag\n\n(This stays local unless you push tags.)" ; then
    (cd "$repo" && git tag -f "$tag" >/dev/null 2>&1) || true
    msgbox "Created local tag:\n\n$tag"
  fi
}

refuse_if_dirty() {
  local repo="$1" action="$2"
  if git_has_changes "$repo"; then
    msgbox "Refusing to run:\n\n$action\n\nRepo has uncommitted changes.\nCommit or stash first.\n\nSafety first."
    return 1
  fi
  return 0
}

git_is_repo() {
  local repo="$1"

  # basic sanity
  [[ -n "${repo:-}" && -d "$repo/.git" ]] || return 1

  # authoritative git check
  (
    cd "$repo" 2>/dev/null &&
    git rev-parse --is-inside-work-tree >/dev/null 2>&1
  )
}

