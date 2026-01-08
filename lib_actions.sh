#!/usr/bin/env bash
# lib_actions.sh - shared action_* (minimal UI via msgbox; calls lib_git)

GUTT_LAST_RC=0
GUTT_REQUIRE_RESTART=0

gutt_run_action() {
  local had_e=0
  [[ $- == *e* ]] && had_e=1
  set +e
  GUTT_REQUIRE_RESTART=0
  "$@"
  GUTT_LAST_RC=$?
  ((had_e)) && set -e

  # 0 = success
  # 2 = user cancel / back (convention used by several menus)
  if [[ $GUTT_LAST_RC -ne 0 && $GUTT_LAST_RC -ne 2 ]]; then
    msgbox "⚠ Action failed (exit $GUTT_LAST_RC):

$*"
  fi

  if [[ $GUTT_LAST_RC -eq 0 && ${GUTT_REQUIRE_RESTART:-0} -eq 1 ]]; then
    msgbox "Restart Required

PATH integration has been removed.
Because shell PATH changes do not affect this current terminal session,
GUTT will now exit.

Please open a new terminal (or run: exec $SHELL) and then rerun GUTT."
    exit 0
  fi
  return 0
}

action_status() { run_git_capture "$1" git status; }

action_full_status() {
  local repo="$1"

  # Defensive: handle being called outside a Git repo (should not happen in normal flow).
  if ! (cd "$repo" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    msgbox "Not a Git repository:\n\n$repo"
    return 0
  fi

  local branch upstream ahead behind
  branch="$(git_current_branch "$repo")"
  upstream="$(git_upstream "$repo")"

  ahead="-"
  behind="-"
  if [[ -n "$upstream" ]]; then
    local ab
    ab="$(cd "$repo" && git rev-list --left-right --count HEAD...@{u} 2>/dev/null || true)"
    if [[ -n "$ab" ]]; then
      read -r ahead behind <<<"$ab"
    fi
  fi

  local staged=0 unstaged=0 untracked=0
  local porcelain x y
  porcelain="$(cd "$repo" && git status --porcelain=v1 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "${line:0:2}" == "??" ]]; then
      ((untracked++))
      continue
    fi
    x="${line:0:1}"
    y="${line:1:1}"
    [[ "$x" != " " && "$x" != "?" ]] && ((staged++))
    [[ "$y" != " " && "$y" != "?" ]] && ((unstaged++))
  done <<<"$porcelain"

  local last
  last="$(cd "$repo" && git log -1 --pretty=format:'%h %cs %s' 2>/dev/null || true)"
  [[ -n "$last" ]] || last="(no commits yet)"

  local up_line
  if [[ -n "$upstream" ]]; then
    up_line="Upstream: $upstream (ahead $ahead, behind $behind)"
  else
    up_line="Upstream: (none)"
  fi

  local tmp
  tmp="$(mktemp_gutt)"
  {
    echo "=== GUTT: Full Status ==="
    echo
    echo "Repo: $repo"
    echo "Branch: $branch"
    echo "$up_line"
    echo
    echo "Changes:"
    echo "  Staged:   $staged"
    echo "  Unstaged: $unstaged"
    echo "  Untracked: $untracked"
    echo
    echo "Last commit:"
    echo "  $last"
    echo
    echo "=== Porcelain (git status --porcelain=v1 -b) ==="
    echo
    (cd "$repo" && git status --porcelain=v1 -b 2>&1) || true
    echo
    echo "=== Human (git status) ==="
    echo
    (cd "$repo" && git status 2>&1) || true
  } >"$tmp"
  textbox "$tmp"
  rm -f "$tmp"
}

action_status_summary() {
  local repo="$1"

  # Defensive: handle being called outside a Git repo (should not happen in normal flow).
  if ! (cd "$repo" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    msgbox "Not a Git repository:\n\n$repo"
    return 0
  fi

  local branch upstream ahead behind
  branch="$(git_current_branch "$repo")"
  upstream="$(git_upstream "$repo")"

  ahead="-"
  behind="-"
  if [[ -n "$upstream" ]]; then
    local ab
    ab="$(cd "$repo" && git rev-list --left-right --count HEAD...@{u} 2>/dev/null || true)"
    if [[ -n "$ab" ]]; then
      read -r ahead behind <<<"$ab"
    fi
  fi

  local staged=0 unstaged=0 untracked=0
  local porcelain line x y
  porcelain="$(cd "$repo" && git status --porcelain=v1 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "${line:0:2}" == "??" ]]; then
      ((untracked++))
      continue
    fi
    x="${line:0:1}"
    y="${line:1:1}"
    [[ "$x" != " " && "$x" != "?" ]] && ((staged++))
    [[ "$y" != " " && "$y" != "?" ]] && ((unstaged++))
  done <<<"$porcelain"

  local last
  last="$(cd "$repo" && git log -1 --pretty=format:'%h %cs %s' 2>/dev/null || true)"
  [[ -n "$last" ]] || last="(no commits yet)"

  local up_line
  if [[ -n "$upstream" ]]; then
    up_line="Upstream: $upstream (ahead $ahead, behind $behind)"
  else
    up_line="Upstream: (none)"
  fi

  msgbox "Repo: $repo\n\nBranch: $branch\n$up_line\n\nChanges:\n  Staged:   $staged\n  Unstaged: $unstaged\n  Untracked: $untracked\n\nLast commit:\n  $last"
}

action_pull() {
  local repo="$1"
  local mode
  mode="$(cfg_get default_pull_mode ff-only)"
  case "$mode" in
    ff-only) run_git_capture "$repo" git pull --ff-only ;;
    rebase)  run_git_capture "$repo" git pull --rebase ;;
    merge|*) run_git_capture "$repo" git pull ;;
  esac
}

action_fetch() {
  local repo="$1"
  local remotes tmpf rc

  remotes="$(cd "$repo" && git remote 2>/dev/null || true)"
  if [[ -z "$remotes" ]]; then
    msgbox "No remotes are configured for this repo.

Add a remote first (Remotes menu)."
    return 1
  fi

  tmpf="$(mktemp_gutt)"
  (cd "$repo" && git fetch --all --prune) >"$tmpf" 2>&1
  rc=$?
  textbox "$tmpf"
  rm -f "$tmpf"

  if [[ $rc -eq 0 ]]; then
    msgbox "Fetch completed successfully."
  else
    msgbox "Fetch failed."
  fi
  return $rc
}

action_pull_safe_update() {
  local repo="$1"
  local branch upstream tmpf rc ab ahead behind

  branch="$(git_current_branch "$repo")"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    msgbox "Cannot pull on a detached HEAD."
    return 1
  fi

  if git_has_changes "$repo"; then
    msgbox "Working tree is not clean.

Stash or commit your changes before pulling.

Pull aborted."
    return 1
  fi

  upstream="$(git_upstream "$repo")"
  if [[ -z "$upstream" ]]; then
    msgbox "No upstream is set for '$branch'.

Set an upstream (tracking) branch first.

Tip: Use Fast Lane 'Push' (it can offer to set upstream),
or use 'Set / view upstream' in the Sync/Branch menus."
    return 1
  fi

  # Preflight (may be stale until we fetch, but still useful context).
  ab="$(cd "$repo" && git rev-list --left-right --count "HEAD...@{u}" 2>/dev/null || true)"
  ahead="${ab%% *}"; behind="${ab##* }"
  [[ -z "$ahead" || "$ahead" == "$ab" ]] && ahead="0"
  [[ -z "$behind" ]] && behind="0"

  if ! whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Pull (safe mode)?

Branch:   $branch
Upstream: $upstream

What will happen:
1) Update remote tracking refs:
   git fetch --all --prune
2) Fast-forward only update (no merges/rebases):
   git merge --ff-only $upstream

Current (may be stale until fetch):
Ahead:   $ahead
Behind:  $behind

Proceed?" 20 72; then
    return 0
  fi

  # Step 1: fetch first (explicit, safe update).
  tmpf="$(mktemp_gutt)"
  (cd "$repo" && git fetch --all --prune) >"$tmpf" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    textbox "$tmpf"
    rm -f "$tmpf"
    msgbox "Fetch failed. Pull aborted."
    return $rc
  fi
  rm -f "$tmpf"

  # Re-check after fetch for accurate ahead/behind and divergence.
  ab="$(cd "$repo" && git rev-list --left-right --count "HEAD...@{u}" 2>/dev/null || true)"
  ahead="${ab%% *}"; behind="${ab##* }"
  [[ -z "$ahead" || "$ahead" == "$ab" ]] && ahead="0"
  [[ -z "$behind" ]] && behind="0"

  if [[ "$behind" == "0" ]]; then
    if [[ "$ahead" != "0" ]]; then
      msgbox "No pull needed.

You are ahead of upstream by $ahead commit(s)."
    else
      msgbox "Already up to date (no commits to pull)."
    fi
    return 0
  fi

  if [[ "$ahead" != "0" ]]; then
    msgbox "Pull aborted.

Your branch appears to have diverged from upstream.

Ahead:  $ahead
Behind: $behind

A merge or rebase would be required, and GUTT will not do that
automatically in Fast Lane."
    return 1
  fi

  # Step 2: fast-forward only merge from upstream.
  tmpf="$(mktemp_gutt)"
  (cd "$repo" && git merge --ff-only "$upstream") >"$tmpf" 2>&1
  rc=$?
  textbox "$tmpf"
  rm -f "$tmpf"

  if [[ $rc -eq 0 ]]; then
    msgbox "Pull completed successfully (fast-forward only)."
  else
    msgbox "Pull aborted.

A fast-forward update was not possible.

This usually means your local branch and upstream have diverged
and a merge or rebase would be required.

GUTT will not do that automatically in Fast Lane."
  fi
  return $rc
}

action_push() {
  local repo="$1"
  local branch upstream remote cmd

  branch="$(git_current_branch "$repo")"
  if [[ -z "$branch" ]]; then
    msgbox "Not a git repo (or cannot read current branch)."
    return 1
  fi
  if [[ "$branch" == "HEAD" ]]; then
    msgbox "Cannot push from a detached HEAD.

Check out a branch first."
    return 1
  fi

  upstream="$(git_upstream "$repo")"

  if [[ -n "$upstream" ]]; then
    if ! whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Push current branch now?

Branch: $branch
Upstream: $upstream

This will run:
  git push" 14 78 3>&1 1>&2 2>&3; then
      msgbox "Cancelled."
      return 0
    fi
    cmd=(git push)
  else
    # Prefer origin if present, else fall back to the first remote.
    if (cd "$repo" && git remote 2>/dev/null | grep -qx "origin"); then
      remote="origin"
    else
      remote="$(cd "$repo" && git remote 2>/dev/null | head -n1 || true)"
    fi

    if [[ -z "$remote" ]]; then
      msgbox "No remotes found.

Add a remote first (for example: origin)."
      return 1
    fi

    if ! whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "No upstream is set for this branch.

Branch: $branch
Upstream: (none)

Set upstream to:
  ${remote}/${branch}

and push now?

This will run:
  git push -u $remote $branch" 18 78 3>&1 1>&2 2>&3; then
      msgbox "Cancelled."
      return 0
    fi

    cmd=(git push -u "$remote" "$branch")
  fi

  # Optional fetch first (safer push feedback).
  if [[ "$(cfg_get auto_fetch_before_push 1)" == "1" ]]; then
    local tmpf rc
    tmpf="$(mktemp_gutt)"
    (cd "$repo" && git fetch --all --prune) >"$tmpf" 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
      textbox "$tmpf"
      rm -f "$tmpf"
      msgbox "Fetch failed. Push aborted."
      return $rc
    fi
    rm -f "$tmpf"
  fi

  local tmpp rc
  tmpp="$(mktemp_gutt)"
  (cd "$repo" && "${cmd[@]}") >"$tmpp" 2>&1
  rc=$?
  textbox "$tmpp"
  rm -f "$tmpp"

  if [[ $rc -eq 0 ]]; then
    msgbox "Push completed successfully."
  else
    msgbox "Push failed.

Review the output for details."
  fi
  return $rc
}

action_set_upstream() {
  local repo="$1"
  local branch upstream

  branch="$(git_current_branch "$repo")"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    msgbox "Cannot manage upstream on a detached HEAD."
    return 1
  fi

  upstream="$(git_upstream "$repo")"

  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Upstream (tracking)

Repo:
$repo

Branch: $branch
Current upstream: ${upstream:-"(none)"}" \
      "VIEW" "View upstream details" \
      "AUTO" "Set upstream to origin/<branch> and publish (push -u)" \
      "PICK" "Set upstream to an existing remote branch (pick)" \
      "UNST" "Unset upstream (guarded)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      VIEW)
        local tmp; tmp="$(mktemp_gutt)"
        {
          echo "Branch:   $branch"
          echo "Upstream: ${upstream:-"(none)"}"
          echo
          echo "Local HEAD:  $(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || true)"
          if [[ -n "$upstream" ]]; then
            echo "Remote HEAD: $(cd "$repo" && git rev-parse --short "$upstream" 2>/dev/null || true)"
          fi
        } >"$tmp"
        textbox "$tmp"
        rm -f "$tmp"
        ;;
      AUTO)
        local remote="origin"
        if ! (cd "$repo" && git remote 2>/dev/null | grep -qx "origin"); then
          remote="$(cd "$repo" && git remote 2>/dev/null | head -n1 || true)"
        fi
        if [[ -z "$remote" ]]; then
          msgbox "No remotes found. Add a remote first."
        else
          if whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Publish '$branch' and set upstream to:

${remote}/${branch}

This will run:
  git push -u $remote $branch

Proceed?" 16 78 3>&1 1>&2 2>&3; then
            run_git_capture "$repo" git push -u "$remote" "$branch"
          else
            msgbox "Cancelled."
          fi
        fi
        ;;
      PICK)
        # Pick a remote, then pick an existing remote branch, then set tracking.
        local remote
        remote="$(cd "$repo" && git remote 2>/dev/null | head -n1 || true)"
        if [[ -z "$remote" ]]; then
          msgbox "No remotes found. Add a remote first."
        fi

        # If multiple remotes exist, let the user choose.
        local rems=()
        while IFS= read -r r; do
          [[ -n "$r" ]] || continue
          rems+=("$r" "" )
        done < <(cd "$repo" && git remote 2>/dev/null || true)

        if (( ${#rems[@]} > 2 )); then
          remote="$(menu "$APP_NAME $VERSION" "Choose remote" "${rems[@]}" "BACK" "Back")" || { upstream="$(git_upstream "$repo")"; continue; }
          [[ "$remote" == "BACK" ]] && { upstream="$(git_upstream "$repo")"; continue; }
        else
          remote="${rems[0]:-$remote}"
        fi

        local tmpb; tmpb="$(mktemp_gutt)"
        (cd "$repo" && git for-each-ref "refs/remotes/${remote}/" --format='%(refname:short)') >"$tmpb" 2>/dev/null || true
        if [[ ! -s "$tmpb" ]]; then
          rm -f "$tmpb"
          msgbox "No remote branches found under '${remote}/'.

Tip: Fetch first, or publish with 'AUTO' to create ${remote}/${branch}."
        fi

        local items=()
        while IFS= read -r rb; do
          [[ -n "$rb" ]] || continue
          # Skip remote HEAD pseudo ref if it appears.
          [[ "$rb" == "${remote}/HEAD" ]] && continue
          items+=("$rb" "" )
        done <"$tmpb"
        rm -f "$tmpb"

        if (( ${#items[@]} == 0 )); then
          msgbox "No selectable remote branches found."
        fi

        local target
        target="$(menu "$APP_NAME $VERSION" "Choose upstream target for '$branch'" "${items[@]}" "BACK" "Back")" || { upstream="$(git_upstream "$repo")"; continue; }
        [[ "$target" == "BACK" ]] && { upstream="$(git_upstream "$repo")"; continue; }

        if whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Set upstream for:
  $branch

to:
  $target

This will run:
  git branch --set-upstream-to=$target $branch

Proceed?" 17 78 3>&1 1>&2 2>&3; then
          run_git_capture "$repo" git branch --set-upstream-to="$target" "$branch"
        else
          msgbox "Cancelled."
        fi
        ;;
      UNST)
        if [[ -z "$upstream" ]]; then
          msgbox "No upstream is set for '$branch'."
        else
          if whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Unset upstream for '$branch'?

Current upstream:
  $upstream

This will run:
  git branch --unset-upstream $branch

Proceed?" 16 78 3>&1 1>&2 2>&3; then
            run_git_capture "$repo" git branch --unset-upstream "$branch"
          else
            msgbox "Cancelled."
          fi
        fi
        ;;
      BACK)
        return 0
        ;;
    esac

    upstream="$(git_upstream "$repo")"
  done
}

action_stage_by_file() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git status --porcelain) >"$tmp" 2>/dev/null || true
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    msgbox "No changes to stage."
    return 0
  fi

  local items=()
  while IFS= read -r line; do
    local st="${line:0:2}"
    local path="${line:3}"
    [[ -n "$path" ]] || continue
    items+=("$path" "$st" "OFF")
  done <"$tmp"
  rm -f "$tmp"

  local selected
  selected="$(whiptail --title "$APP_NAME $VERSION" --separate-output --checklist "Select files to stage" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)" || return 0
  [[ -n "${selected//$'\n'/}" ]] || return 0
  local -a paths=()
  mapfile -t paths <<<"$selected"
  (cd "$repo" && git add -- "${paths[@]}") || true
}

action_unstage_by_file() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git diff --cached --name-only) >"$tmp" 2>/dev/null || true
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    msgbox "No staged files."
    return 0
  fi
  local items=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    items+=("$path" "" "OFF")
  done <"$tmp"
  rm -f "$tmp"

  local selected rc=0 had_e=0
  [[ $- == *e* ]] && had_e=1
  set +e
  selected="$(whiptail --title "$APP_NAME $VERSION" --separate-output --checklist "Select files to unstage" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)"
  rc=$?
  ((had_e)) && set -e
  [[ $rc -eq 0 ]] || return 0
  [[ -n "${selected//$'\n'/}" ]] || return 0
  local -a paths=()
  mapfile -t paths <<<"$selected"
  (cd "$repo" && git restore --staged -- "${paths[@]}") || true
}

action_discard_file() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git status --porcelain) >"$tmp" 2>/dev/null || true
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    msgbox "No changes to discard."
    return 0
  fi
  local items=()
  while IFS= read -r line; do
    local path="${line:3}"
    [[ -n "$path" ]] || continue
    items+=("$path" "")
  done <"$tmp"
  rm -f "$tmp"

  local pick rc=0 had_e=0
  [[ $- == *e* ]] && had_e=1
  set +e
  pick="$(whiptail --title "$APP_NAME $VERSION" --menu "Select a file to discard changes (restore from HEAD). DANGER." 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)"
  rc=$?
  ((had_e)) && set -e
  [[ $rc -eq 0 ]] || return 0

  if danger_preflight "$repo" "Discard changes to: $pick"; then
    offer_backup_tag "$repo"
    run_git_capture "$repo" git restore --worktree --staged -- "$pick"
  fi
}

action_commit() {
  local repo="$1"
  local staged
  staged="$(cd "$repo" && git diff --cached --name-only 2>/dev/null | head -n1 || true)"
  if [[ -z "$staged" ]]; then
    msgbox "No staged changes.\n\nStage files first."
    return 1
  fi

  # Guided view: show status + staged summary before asking for the message.
  local tmp br
  tmp="$(mktemp_gutt)"
  br="$(git_current_branch "$repo")"

  (
    cd "$repo" 2>/dev/null || exit 0
    echo "Commit (guided)"
    echo "==============="
    echo
    echo "repo   : $repo"
    echo "branch : $br"
    if [[ "$br" == "HEAD" || -z "$br" ]]; then
      echo "note   : detached HEAD"
    fi
    echo
    echo "Working tree (git status -sb):"
    echo "------------------------------"
    git status -sb 2>/dev/null || true
    echo
    echo "Staged files (git diff --cached --name-status):"
    echo "----------------------------------------------"
    git diff --cached --name-status 2>/dev/null || true
    echo
    echo "Staged diffstat (git diff --cached --stat):"
    echo "------------------------------------------"
    git diff --cached --stat 2>/dev/null || true
  ) >"$tmp" 2>/dev/null || true

  textbox "$tmp"
  rm -f "$tmp"

  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Commit (guided)" \
      "VIEW" "View staged diff (full)" \
      "GO"   "Proceed to commit message" \
      "CANC" "Cancel")" || return 0

    case "$choice" in
      VIEW)
        local tmpd lines
        tmpd="$(mktemp_gutt)"
        (cd "$repo" && git diff --cached 2>/dev/null) >"$tmpd" 2>/dev/null || true
        lines="$(wc -l <"$tmpd" 2>/dev/null || echo 0)"
        if [[ "$lines" -gt 2000 ]]; then
          if ! yesno "Staged diff is large (${lines} lines).\n\nOpen anyway?" ; then
            rm -f "$tmpd"
            continue
          fi
        fi
        textbox "$tmpd"
        rm -f "$tmpd"
        ;;
      GO)
        break
        ;;
      CANC)
        return 0
        ;;
    esac
  done

  local msg
  msg="$(inputbox "Commit message" "")" || return 1
  [[ -n "$msg" ]] || { msgbox "Empty commit message refused."; return 1; }
  if ! yesno "Commit staged changes with this message?\n\n$msg" ; then
    return 0
  fi

  run_git_capture "$repo" git commit -m "$msg"
}

action_commit_preview() {
  local repo="$1"

  # Preview only: no staging, no commits.
  local br up counts ahead behind
  br="$(git_current_branch "$repo")"
  up="$(cd "$repo" && git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
  ahead="?"
  behind="?"
  if [[ -n "$up" ]]; then
    counts="$(cd "$repo" && git rev-list --left-right --count HEAD..."$up" 2>/dev/null || true)"
    if [[ -n "$counts" ]]; then
      ahead="${counts%%[[:space:]]*}"
      behind="${counts##*[[:space:]]}"
    fi
  fi

  local tmp
  tmp="$(mktemp_gutt)"
  (
    cd "$repo" 2>/dev/null || exit 0
    echo "Commit preview (no changes made)"
    echo "==============================="
    echo
    echo "repo   : $repo"
    echo "branch : ${br:-?}"
    if git_is_detached "$repo"; then
      echo "note   : detached HEAD"
    fi
    if [[ -n "$up" ]]; then
      echo "upstream: $up (ahead $ahead, behind $behind)"
    else
      echo "upstream: (none)"
    fi
    echo

    echo "Working tree (git status -sb):"
    echo "------------------------------"
    git status -sb 2>/dev/null || true
    echo

    echo "Staged (cached) diffstat:"
    echo "------------------------"
    if git diff --cached --quiet 2>/dev/null; then
      echo "(none)"
    else
      git diff --cached --stat 2>/dev/null || true
    fi
    echo

    echo "Unstaged (working tree) diffstat:"
    echo "--------------------------------"
    if git diff --quiet 2>/dev/null; then
      echo "(none)"
    else
      git diff --stat 2>/dev/null || true
    fi
    echo

    echo "Untracked files:"
    echo "---------------"
    local any=0
    while IFS= read -r f; do
      any=1
      printf '%s\n' "$f"
    done < <(git ls-files --others --exclude-standard 2>/dev/null || true)
    if [[ "$any" -eq 0 ]]; then
      echo "(none)"
    fi
  ) >"$tmp" 2>/dev/null || true

  textbox "$tmp"
  rm -f "$tmp"

  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Commit preview (no changes made)" \
      "SDF" "View staged diff (full)" \
      "UDF" "View unstaged diff (full)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      SDF)
        local tmpd lines
        tmpd="$(mktemp_gutt)"
        (cd "$repo" && git diff --cached 2>/dev/null) >"$tmpd" 2>/dev/null || true
        lines="$(wc -l <"$tmpd" 2>/dev/null || echo 0)"
        if [[ "$lines" -gt 2000 ]]; then
          if ! yesno "Staged diff is large (${lines} lines).\n\nOpen anyway?" ; then
            rm -f "$tmpd"
            continue
          fi
        fi
        textbox "$tmpd"
        rm -f "$tmpd"
        ;;
      UDF)
        local tmpu lines
        tmpu="$(mktemp_gutt)"
        (cd "$repo" && git diff 2>/dev/null) >"$tmpu" 2>/dev/null || true
        lines="$(wc -l <"$tmpu" 2>/dev/null || echo 0)"
        if [[ "$lines" -gt 2000 ]]; then
          if ! yesno "Unstaged diff is large (${lines} lines).\n\nOpen anyway?" ; then
            rm -f "$tmpu"
            continue
          fi
        fi
        textbox "$tmpu"
        rm -f "$tmpu"
        ;;
      BACK)
        return 0
        ;;
    esac
  done
}

action_commit_all() {
  local repo="$1"
  ensure_repo "$repo" || return 1

  if ! repo_dirty "$repo"; then
    msgbox "No changes to commit."
    return 0
  fi

  # Guard thresholds (tune later if needed, but keep stable for now).
  local COUNT_THRESHOLD=25
  local LINES_THRESHOLD=2000

  local tmp br
  tmp="$(mktemp_gutt)"
  br="$(git_current_branch "$repo")"

  local count total_lines
  count="$(cd "$repo" && git status --porcelain=v1 2>/dev/null | wc -l | tr -d ' ')"
  total_lines="$(
    cd "$repo" 2>/dev/null || exit 0
    {
      git diff --numstat 2>/dev/null || true
      git diff --cached --numstat 2>/dev/null || true
    } | awk '{ if ($1 != "-") a += $1; if ($2 != "-") d += $2 } END { print (a + d + 0) }'
  )"

  (
    cd "$repo" 2>/dev/null || exit 0
    echo "Repo: $repo"
    echo "Branch: $br"
    if git_is_detached "$repo"; then
      echo "Note: detached HEAD"
    fi
    echo
    echo "This will stage and commit ALL changes (including untracked)."
    echo
    echo "Summary:"
    echo "  Entries (status lines): $count"
    echo "  Approx. changed lines:  $total_lines  (adds+deletes; binary ignored)"
    echo
    echo "Working tree:"
    git status -sb 2>/dev/null || true
    echo
    echo "Changes (porcelain):"
    git status --porcelain=v1 2>/dev/null || true
  ) >"$tmp"

  textbox "Commit all (preview)" "$tmp"
  rm -f "$tmp"

  if [[ "${count:-0}" -ge "$COUNT_THRESHOLD" || "${total_lines:-0}" -ge "$LINES_THRESHOLD" ]]; then
    local tok
    tok="$(inputbox "Large change set detected.\n\nEntries: $count (>= $COUNT_THRESHOLD) or Lines: $total_lines (>= $LINES_THRESHOLD)\n\nType ALL to continue" "")" || return 1
    [[ "$tok" == "ALL" ]] || { msgbox "Cancelled."; return 0; }
  fi

  if ! yesno "Stage and commit ALL changes in this repo?\n\nThis includes untracked files.\n\nProceed?" ; then
    return 0
  fi

  run_git_capture "$repo" git add -A

  # Reuse guided commit flow (shows staged/unstaged, lets you view staged diff, etc.).
  action_commit "$repo"
}

action_checkpoint_commit() {
  local repo="$1"

  ensure_repo "$repo" || return 1
  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }

  # If nothing is dirty and nothing is staged, there's nothing to checkpoint.
  if (cd "$repo" && git diff --quiet && git diff --cached --quiet); then
    local untracked
    untracked="$(cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | head -n1 || true)"
    if [[ -z "$untracked" ]]; then
      msgbox "Nothing to checkpoint.\n\nNo staged/unstaged/untracked changes."
      return 0
    fi
  fi

  # Show a short status overview (guided, read-only).
  run_git_capture "$repo" git status -sb

  # If nothing staged, offer to stage everything (default NO).
  if (cd "$repo" && git diff --cached --quiet); then
    if yesno "No staged changes.\n\nStage ALL current changes (git add -A) for a WIP checkpoint?\n\nDefault is NO." ; then
      run_git_capture "$repo" git add -A
    else
      msgbox "Cancelled.\n\nStage files first, then retry."
      return 0
    fi
  fi

  # Re-check staged presence.
  if (cd "$repo" && git diff --cached --quiet); then
    msgbox "No staged changes.\n\nNothing to checkpoint."
    return 0
  fi

  # Guard: if this is a huge change set, require an explicit typed token.
  local COUNT_THRESHOLD=25
  local LINES_THRESHOLD=2000
  local count total_lines tmp
  tmp="$(mktemp_gutt)"
  # Count tracked changed entries in working tree + index.
  (cd "$repo" && git status --porcelain) >"$tmp" 2>/dev/null || true
  count="$(grep -c '^[ MADRCU?!]' "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"

  total_lines=0
  while IFS=$'\t' read -r a d _; do
    [[ "$a" == "-" || "$d" == "-" ]] && continue
    [[ -n "$a" ]] && total_lines=$((total_lines + a))
    [[ -n "$d" ]] && total_lines=$((total_lines + d))
  done < <(cd "$repo" && { git diff --numstat; git diff --cached --numstat; } 2>/dev/null || true)

  if [[ "${count:-0}" -ge "$COUNT_THRESHOLD" || "${total_lines:-0}" -ge "$LINES_THRESHOLD" ]]; then
    local tok
    tok="$(inputbox "Large change set detected.\n\nEntries: $count (>= $COUNT_THRESHOLD) or Lines: $total_lines (>= $LINES_THRESHOLD)\n\nType WIP to continue" "")" || return 1
    [[ "$tok" == "WIP" ]] || { msgbox "Cancelled."; return 0; }
  fi

  # Default message with timestamp (user can edit).
  local default_msg msg
  default_msg="WIP: checkpoint $(date '+%Y-%m-%d %H:%M')"
  msg="$(inputbox "Checkpoint commit message (WIP)" "$default_msg")" || return 0

  # Trim whitespace for emptiness checks.
  local msg_trim
  msg_trim="${msg//[[:space:]]/}"
  if [[ -z "$msg_trim" ]]; then
    msg="WIP: checkpoint"
  fi

  if ! yesno "Create a WIP checkpoint commit with this message?\n\n$msg\n\nProceed?" ; then
    return 0
  fi

  run_git_capture "$repo" git commit -m "$msg"
}

action_amend() {
  local repo="$1"

  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }

  # Ensure we actually have a commit to amend.
  if ! (cd "$repo" && git rev-parse --verify HEAD >/dev/null 2>&1); then
    msgbox "No commits yet. Nothing to amend."
    return 1
  fi

  # Show context first (read-only).
  run_git_capture "$repo" git log -1 --oneline --decorate
  run_git_capture "$repo" git status -sb

  # Strong guard: explicit typed confirmation.
  local typed
  typed="$(inputbox "Type AMEND to continue" "")" || return 0
  [[ "$typed" == "AMEND" ]] || { msgbox "Cancelled."; return 0; }

  # Decide whether to include working-tree changes.
  local choice
  choice="$(menu "$APP_NAME $VERSION" "Amend last commit (repo: $repo)"     "KEEP" "Keep commit message (no edit)"     "EDIT" "Edit commit message (open editor)"     "CANC" "Cancel")" || return 0

  case "$choice" in
    KEEP)
      # If the user has unstaged/staged changes and wants them included, they should stage first.
      if yesno "Include ALL current changes (stage everything) before amending?

Default is NO." ; then
        run_git_capture "$repo" git add -A
      fi
      run_git_capture "$repo" git commit --amend --no-edit
      ;;
    EDIT)
      if yesno "Include ALL current changes (stage everything) before amending?

Default is NO." ; then
        run_git_capture "$repo" git add -A
      fi
      run_git_capture "$repo" git commit --amend
      ;;
    *)
      return 0
      ;;
  esac
}

action_reword_last() {
  local repo="$1"

  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }

  # Refuse if there is no HEAD yet (no commits).
  (cd "$repo" && git rev-parse --verify HEAD >/dev/null 2>&1) || {
    msgbox "No commits yet. Nothing to reword."
    return 1
  }

  # Safety: refuse if anything is staged, to avoid accidentally amending content.
  if ! (cd "$repo" && git diff --cached --quiet) ; then
    msgbox "Staged changes detected.

Reword-only refuses to proceed to avoid accidentally changing commit contents.

Use: Amend last commit"
    return 1
  fi

  # Context: show the last commit and its full message.
  run_git_capture "$repo" git log -1 --oneline --decorate
  local tmp
  tmp="$(mktemp_gutt)"
  (cd "$repo" && git log -1 --pretty=format:%B) >"$tmp" 2>&1 || true
  textbox "$tmp"
  rm -f "$tmp"

  # Warn if working tree is dirty (unstaged changes or untracked files).
  local dirty="NO"
  if ! (cd "$repo" && git diff --quiet) ; then
    dirty="YES"
  fi
  local untracked_count
  untracked_count="$(cd "$repo" && git ls-files --others --exclude-standard | wc -l | tr -d ' ')"
  if [[ "$dirty" == "YES" || "${untracked_count:-0}" -gt 0 ]] ; then
    if ! yesno "Working tree is not clean (unstaged changes and/or untracked files present).

That will NOT be included in the amended commit (because nothing is staged), but it can confuse reviews.

Proceed anyway?" ; then
      return 0
    fi
  fi

  local current_subject
  current_subject="$(cd "$repo" && git log -1 --pretty=%s 2>/dev/null || true)"

  local msg
  msg="$(inputbox "New message for last commit (reword only)" "$current_subject")" || return 1
  [[ -n "$msg" ]] || { msgbox "Empty message refused."; return 1; }

  local token
  token="$(inputbox "Type REWORD to confirm rewriting history" "")" || return 1
  [[ "$token" == "REWORD" ]] || { msgbox "Cancelled."; return 0; }

  if ! yesno "Reword last commit message?

This rewrites history.
If this commit was already pushed, you will likely need force-with-lease.

Proceed?" ; then
    return 0
  fi

  run_git_capture "$repo" git commit --amend -m "$msg"
}

action_undo_last_soft() {
  local repo="$1"

  if ! git_is_repo "$repo"; then
    msgbox "Not a git repo: $repo"
    return 1
  fi

  local br
  br="$(git_current_branch "$repo")"
  if [[ "$br" == "HEAD" || -z "$br" ]]; then
    msgbox "Detached HEAD detected.

Undo last commit refuses to proceed on detached HEAD."
    return 1
  fi

  if ! (cd "$repo" && git rev-parse --verify HEAD >/dev/null 2>&1); then
    msgbox "No commits found in this repo.

Nothing to undo."
    return 1
  fi

  # Safety: avoid mixing the undone commit with other local changes.
  if git_has_changes "$repo"; then
    msgbox "Working tree is not clean.

Undo last commit (soft) refuses to proceed to avoid mixing changes.
Commit/stash/discard your current changes first."
    return 1
  fi

  if ! (cd "$repo" && git rev-parse --verify HEAD~1 >/dev/null 2>&1); then
    msgbox "This repo appears to have only a single commit.

Undo last commit (soft) needs HEAD~1.
Use the Reset menu (advanced) if you truly need to rewrite the root commit."
    return 1
  fi

  # Context
  run_git_capture "$repo" git log -2 --oneline --decorate

  local token
  token="$(inputbox "Type UNDO to confirm rewriting history" "")" || return 1
  [[ "$token" == "UNDO" ]] || { msgbox "Cancelled."; return 0; }

  if ! yesno "Undo last commit (SOFT reset)?

This rewrites history.
It moves HEAD back by 1 commit and keeps the undone commit's changes STAGED.

If this commit was already pushed, you will likely need force-with-lease.

Proceed?" ; then
    return 0
  fi

  run_git_capture "$repo" git reset --soft HEAD~1
  run_git_capture "$repo" git status -sb
}

action_stash_push() {
  local repo="$1"
  if ! git_has_changes "$repo"; then
    msgbox "No changes to stash."
    return 0
  fi
  local msg
  msg="$(inputbox "Stash message (optional)" "")" || msg=""
  if [[ -n "$msg" ]]; then
    run_git_capture "$repo" git stash push -m "$msg"
  else
    run_git_capture "$repo" git stash push
  fi
}

action_stash_push_quick() {
  local repo="$1"
  ensure_repo "$repo" || return 1

  if ! repo_dirty "$repo"; then
    msgbox "No changes to stash."
    return 0
  fi

  local ts msg tmp rc last
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  msg="gutt quick stash $ts"

  tmp="$(mktemp_gutt)"
  (cd "$repo" && git stash push -m "$msg") >"$tmp" 2>&1
  rc=$?
  textbox "$tmp"
  rm -f "$tmp"
  (( rc == 0 )) || return 1

  # Show the most recent stash reference clearly
  last="$(cd "$repo" && git stash list -n 1 2>/dev/null || true)"
  if [[ -n "$last" ]]; then
    msgbox "Stashed changes successfully:

$last"
  else
    msgbox "Stashed changes successfully."
  fi
}

action_stash_apply() { local s; s="$(stash_pick "$1")" || return 0; run_git_capture "$1" git stash apply "$s"; }

action_stash_pop()   { local s; s="$(stash_pick "$1")" || return 0; run_git_capture "$1" git stash pop "$s"; }

action_stash_drop() {
  local repo="$1"
  local s
  s="$(stash_pick "$repo")" || return 0
  yesno "Drop stash:\n\n$s\n\nProceed?" && run_git_capture "$repo" git stash drop "$s"
}

action_stash_branch() {
  local repo="$1"
  local s br
  s="$(stash_pick "$repo")" || return 0
  br="$(inputbox "New branch name to create from $s" "")" || return 0
  [[ -n "$br" ]] || return 0
  run_git_capture "$repo" git stash branch "$br" "$s"
}

action_branch_create() {
  local repo="$1"
  local name
  name="$(inputbox "New branch name" "")" || return 0
  [[ -n "$name" ]] || return 0
  run_git_capture "$repo" git branch "$name"
}

action_branch_switch() {
  local repo="$1"

  local cur
  if git_is_detached "$repo"; then
    cur="(detached)"
  else
    cur="$(git_current_branch "$repo")"
  fi

  if git_has_changes "$repo"; then
    msgbox "Warning: working tree has uncommitted changes.

Switching branches may carry changes across.
If unsure, stash or commit first."
  fi

  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git branch --format='%(refname:short)') >"$tmp" 2>/dev/null || true
  [[ -s "$tmp" ]] || { rm -f "$tmp"; msgbox "No local branches found."; return 1; }

  local items=()
  local b desc
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    desc=""
    [[ "$b" == "$cur" ]] && desc="current"
    items+=("$b" "$desc")
  done <"$tmp"
  rm -f "$tmp"

  local choice rc=0 had_e=0
  [[ $- == *e* ]] && had_e=1
  set +e
  choice="$(whiptail --title "$APP_NAME $VERSION" --menu "Select a branch

Current: $cur" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)"
  rc=$?
  ((had_e)) && set -e
  [[ $rc -eq 0 ]] || return 0
  [[ -n "$choice" ]] || return 0

  if [[ "$choice" == "$cur" ]]; then
    msgbox "Already on:

$cur"
    return 0
  fi

  run_git_capture "$repo" git switch "$choice"
}

action_branch_rename() {
  local repo="$1"
  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }
  local cur name
  cur="$(git_current_branch "$repo")"
  name="$(inputbox "Rename current branch '$cur' to" "$cur")" || return 0
  [[ -n "$name" ]] || return 0
  run_git_capture "$repo" git branch -m "$name"
}

action_branch_delete() {
  local repo="$1"
  if git_has_changes "$repo"; then
    msgbox "Refusing while repo has uncommitted changes."
    return 1
  fi
  local b cur
  b="$(pick_branch "$repo")" || return 0
  cur="$(git_current_branch "$repo")"
  if [[ "$b" == "$cur" ]]; then
    msgbox "Refusing to delete the currently checked-out branch."
    return 1
  fi
  yesno "Delete local branch:\n\n$b\n\nProceed?" && run_git_capture "$repo" git branch -d "$b"
}

action_merge_branch() {
  local repo="$1"
  if git_has_changes "$repo"; then
    msgbox "Refusing to merge with uncommitted changes.\n\nCommit or stash first."
    return 1
  fi
  local b cur
  b="$(pick_branch "$repo")" || return 0
  cur="$(git_current_branch "$repo")"
  [[ "$b" == "$cur" ]] && { msgbox "You selected the current branch."; return 0; }
  run_git_capture "$repo" git merge "$b"
  if (cd "$repo" && git diff --name-only --diff-filter=U | head -n1 >/dev/null 2>&1); then
    msgbox "Merge conflicts detected.\n\nGUTT will not auto-resolve conflicts.\nOpen your editor, resolve, then stage + commit."
  fi
}

action_interactive_rebase() {
  local repo="$1"
  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }
  if git_has_changes "$repo"; then msgbox "Refusing with uncommitted changes."; return 1; fi
  danger_preflight "$repo" "Interactive rebase" || return 0
  offer_backup_tag "$repo"
  local base
  base="$(inputbox "Rebase onto (e.g. HEAD~5 or a commit hash)" "HEAD~5")" || return 0
  [[ -n "$base" ]] || return 0
  run_git_capture "$repo" git rebase -i "$base"
}

action_remote_add() {
  local repo="$1"
  local name url
  name="$(inputbox "Remote name" "origin")" || return 0
  url="$(inputbox "Remote URL" "")" || return 0
  [[ -n "$name" && -n "$url" ]] || return 0
  run_git_capture "$repo" git remote add "$name" "$url"
}

action_remote_seturl() {
  local repo="$1"
  local r url
  r="$(pick_remote "$repo")" || return 0
  url="$(inputbox "New URL for remote '$r'" "")" || return 0
  [[ -n "$url" ]] || return 0
  run_git_capture "$repo" git remote set-url "$r" "$url"
}

action_remote_remove() {
  local repo="$1"
  local r
  r="$(pick_remote "$repo")" || return 0
  yesno "Remove remote:\n\n$r\n\nProceed?" && run_git_capture "$repo" git remote remove "$r"
}

action_show_commit() {
  local repo="$1"
  local h
  h="$(inputbox "Enter commit hash (short ok)" "")" || return 0
  [[ -n "$h" ]] || return 0
  run_git_capture "$repo" git show "$h"
}

action_diff_upstream() {
  local repo="$1"
  local u
  u="$(git_upstream "$repo")"
  [[ -n "$u" ]] || { msgbox "No upstream set."; return 1; }
  run_git_capture "$repo" git diff "$u"...HEAD
}

action_clean_untracked() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git clean -nd) >"$tmp" 2>&1 || true
  textbox "$tmp"
  rm -f "$tmp"

  yesno "Proceed to delete the untracked files listed in the dry-run?\n\nThis cannot be undone." || return 0
  danger_preflight "$repo" "git clean -fd" || return 0
  offer_backup_tag "$repo"
  run_git_capture "$repo" git clean -fd
}

action_force_push() {
  local repo="$1"

  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }
  refuse_if_dirty "$repo" "force push" || return 1

  # Phase 11.3: only allow --force-with-lease (no plain --force)
  local mode phrase u remote branchref
  mode="force-with-lease"
  phrase="$(cfg_get confirm_phrase_forcepush OVERWRITE REMOTE)"

  u="$(git_upstream "$repo")"
  [[ -n "$u" ]] || { msgbox "No upstream set.

Set upstream first."; return 1; }

  remote="${u%%/*}"
  branchref="${u#*/}"
  [[ -n "$remote" ]] || remote="origin"

  # Default NO confirmation (do not rely on the global yesno wrapper here)
  if ! whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Force push (with lease) is guarded.

This can overwrite remote history.

Upstream:
$u

Proceed to view the preflight summary?" 14 78 3>&1 1>&2 2>&3
  then
    return 0
  fi

  # Refresh remote tracking info so the summary is meaningful
  ( cd "$repo" && git fetch "$remote" --prune >/dev/null 2>&1 ) || true

  local tmp; tmp="$(mktemp_gutt)"
  {
    echo "About to FORCE PUSH (mode: --$mode)"
    echo
    echo "Upstream: $u"
    echo "Local HEAD:   $(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || true)"
    echo "Remote HEAD:  $(cd "$repo" && git rev-parse --short "$u" 2>/dev/null || echo "(unknown - fetch failed or ref missing)")"
    echo
    local behind ahead
    behind="$(cd "$repo" && git rev-list --left-right --count "$u...HEAD" 2>/dev/null | awk '{print $1}' || echo "?")"
    ahead="$(cd "$repo" && git rev-list --left-right --count "$u...HEAD" 2>/dev/null | awk '{print $2}' || echo "?")"
    echo "Ahead/behind (local vs upstream): +$ahead / -$behind"
    echo
    echo "This can overwrite remote history."
    echo
    echo "Command:"
    echo "  git push --$mode $remote HEAD:$branchref"
    echo
    echo "Safety tag:"
    echo "  A local safety tag will be created automatically before the push."
  } >"$tmp"
  textbox "$tmp" || true
  rm -f "$tmp"

  confirm_phrase "Final confirmation required.

This can overwrite remote history.

Type the phrase to continue:" "$phrase" || { msgbox "Cancelled."; return 0; }
  danger_preflight "$repo" "Force push (with lease) to $u" || return 0

  # Mandatory safety tag creation
  local ts tag
  ts="$(date +%Y%m%d-%H%M%S)"
  tag="gutt/safety-before-forcepush-$ts"
  if ! (cd "$repo" && git tag -f "$tag" >/dev/null 2>&1); then
    msgbox "Refusing to continue.

Failed to create safety tag:

$tag"
    return 1
  fi

  msgbox "Safety tag created:

$tag

Proceeding with push (with lease)."

  run_git_capture "$repo" git push --"$mode" "$remote" "HEAD:$branchref"
}

action_no_paper_trail() {
  local repo="$1"
  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }
  refuse_if_dirty "$repo" "history rewrite" || return 1

  danger_preflight "$repo" "Rewrite history to a single baseline commit" || return 0
  offer_backup_tag "$repo"

  local msg cur new phrase
  msg="$(inputbox "Single baseline commit message" "Initial commit")" || return 0
  [[ -n "$msg" ]] || { msgbox "Empty message refused."; return 1; }
  cur="$(git_current_branch "$repo")"
  new="$(inputbox "Temporary orphan branch name" "clean-main")" || return 0
  [[ -n "$new" ]] || return 0

  phrase="$(cfg_get confirm_phrase_forcepush OVERWRITE REMOTE)"
  confirm_phrase "This rewrites local history.\n\nIf the remote already has commits, you may need a force push afterwards.\n\nType the phrase to continue:" "$phrase" || { msgbox "Cancelled."; return 0; }

  local tmp; tmp="$(mktemp_gutt)"
  (
    set -e
    cd "$repo"
    git checkout --orphan "$new"
    git rm -rf . >/dev/null 2>&1 || true
    git add -A
    git commit -m "$msg"
    git branch -M "$new" "$cur"
    git switch "$cur"
  ) >"$tmp" 2>&1 || true
  textbox "$tmp"
  rm -f "$tmp"

  msgbox "Baseline rewrite done locally.\n\nIf remote already has history, use:\nDanger zone -> Force push (with lease)."
}


# ---- vNext actions (moved from ui_menus.sh; keep UI layer clean) ----

vnext_create_feature_branch() {
  local repo="$1"
  local action="Create feature branch (from main)"

  refuse_if_dirty "$repo" "$action" || return 1

  local main branch
  main="$(git_detect_main_branch "$repo")"

  if ! git_branch_exists "$repo" "$main"; then
    msgbox "Could not find the primary branch locally.\n\nTried: $main\n\nTip: fetch or create it first."
    return 1
  fi

  # Switch to main safely (prefer git switch, fall back to checkout for older Git).
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git switch "$main" >/dev/null 2>"$tmp") || (cd "$repo" && git checkout "$main" >/dev/null 2>"$tmp") || {
    textbox "$tmp"
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"

  # Update main safely (fetch first + fast-forward only)
  action_pull_safe_update "$repo" || return 1

  # Prompt for new branch name
  local def="feature/"
  while true; do
    branch="$(inputbox "Feature branch name (will be created from main)\n\nRules:\n- no spaces\n- avoid 'main'/'master'" "$def")" || return 1
    [[ -n "$branch" ]] || { msgbox "Empty branch name refused."; continue; }

    if validate_branch_name "$repo" "$branch"; then
      break
    fi
    msgbox "Invalid branch name:\n\n$branch\n\nTry again."
  done

  tmp="$(mktemp_gutt)"
  (cd "$repo" && git switch -c "$branch" >/dev/null 2>"$tmp") || (cd "$repo" && git checkout -b "$branch" >/dev/null 2>"$tmp") || {
    textbox "$tmp"
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"

  local sum; sum="$(mktemp_gutt)"
  repo_summary "$repo" > "$sum"
  textbox "$sum"
  rm -f "$sum"
}


vnext_run_smoke_tests() {
  local repo="$1"
  local tmp rc=0
  tmp="$(mktemp_gutt)"

  {
    echo "GUTT vNext: Smoke tests"
    echo
    echo "Repo:   $repo"
    echo "Branch: $(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    echo "HEAD:   $(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || true)"
    echo
  } > "$tmp"

  local script=""
  local cand
  for cand in "scripts/smoke.sh" "smoke.sh" "test.sh"; do
    if [[ -f "$repo/$cand" ]]; then
      script="$cand"
      break
    fi
  done

  if [[ -n "$script" ]]; then
    {
      echo "Detected smoke script: ./$script"
      echo "Running..."
      echo
    } >> "$tmp"

    (
      cd "$repo"
      # Run via bash for predictable behaviour even if not executable.
      bash "./$script"
    ) >> "$tmp" 2>&1 || rc=$?

    {
      echo
      if [[ "$rc" -eq 0 ]]; then
        echo "RESULT: PASS"
      else
        echo "RESULT: FAIL (exit code $rc)"
      fi
    } >> "$tmp"
  else
    {
      echo "No smoke script found (./scripts/smoke.sh, ./smoke.sh, ./test.sh)."
      echo "Falling back to bash syntax checks for *.sh files."
      echo
    } >> "$tmp"

    local found=0 bad=0
    while IFS= read -r -d '' f; do
      found=1
      if (cd "$repo" && bash -n "${f#./}" ) >> "$tmp" 2>&1; then
        echo "OK:   ${f#./}" >> "$tmp"
      else
        echo "FAIL: ${f#./}" >> "$tmp"
        bad=1
      fi
    done < <(cd "$repo" && find . -type f -name '*.sh' -not -path './.git/*' -print0 2>/dev/null)

    if [[ "$found" -eq 0 ]]; then
      echo "No shell scripts found to check." >> "$tmp"
      rc=0
    elif [[ "$bad" -eq 0 ]]; then
      echo >> "$tmp"
      echo "RESULT: PASS (bash -n)" >> "$tmp"
      rc=0
    else
      echo >> "$tmp"
      echo "RESULT: FAIL (bash -n)" >> "$tmp"
      rc=1
    fi
  fi

  textbox "$tmp"
  rm -f "$tmp"
  return "$rc"
}


vnext_list_tags() {
  local repo="$1"
  local tmp tags_tmp head branch points

  tmp="$(mktemp_gutt)"
  tags_tmp="$(mktemp_gutt)"

  # Header: show where we are and any tags that point at HEAD (useful "am I on known-good?" check)
  head="$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo "?")"
  branch="$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  points="$(cd "$repo" && git tag --points-at HEAD 2>/dev/null | sort | tr '
' ' ' | sed 's/[[:space:]]*$//')"

  {
    echo "Repo:   $repo"
    echo "Branch: $branch"
    echo "HEAD:   $head"
    if [[ -n "$points" ]]; then
      echo "Tags @ HEAD: $points"
    else
      echo "Tags @ HEAD: (none)"
    fi
    echo
    echo "Legend: A=annotated tag, L=lightweight tag"
    echo
    printf "%-2s  %-32s  %-10s  %-10s  %s
" "T" "TAG" "COMMIT" "DATE" "SUBJECT"
    printf "%-2s  %-32s  %-10s  %-10s  %s
" "--" "--------------------------------" "--------" "----------" "------------------------------"
  } >"$tmp"

  # Tag list (read-only). We classify annotated vs lightweight by objecttype:
  # - annotated: objecttype=tag
  # - lightweight: objecttype=commit (or other)
  (cd "$repo" && git for-each-ref --sort=-creatordate     --format='%(objecttype)	%(refname:short)	%(objectname:short)	%(creatordate:short)	%(subject)'     refs/tags) 2>/dev/null | awk -F'	' '
      {
        t = ($1 == "tag") ? "A" : "L"
        tag=$2; c=$3; d=$4; s=$5
        if (s == "") s="(no subject)"
        printf "%-2s  %-32s  %-10s  %-10s  %s
", t, tag, c, d, s
      }
    ' >"$tags_tmp" || true

  if [[ ! -s "$tags_tmp" ]]; then
    echo "No tags found." >>"$tmp"
  else
    cat "$tags_tmp" >>"$tmp"
  fi

  textbox "$tmp"
  rm -f "$tmp" "$tags_tmp"
}


vnext_create_annotated_tag() {
  local repo="$1"
  local tag msg tmp

  vnext_list_tags "$repo"

  tag="$(inputbox "Create annotated tag\n\nEnter tag name:" "")" || return 0
  tag="${tag## }"; tag="${tag%% }"

  if ! validate_tag_name "$tag"; then
    msgbox "Invalid tag name:\n\n$tag"
    return 0
  fi

  msg="$(inputbox "Tag message (annotation):" "Release / checkpoint")" || return 0

  tmp="$(mktemp_gutt)"
  (cd "$repo" && git tag -a "$tag" -m "$msg") >"$tmp" 2>&1 || true
  if git_tag_exists "$repo" "$tag"; then
    echo -e "Created annotated tag:\n\n$tag\n" >"$tmp"
    textbox "$tmp"
  else
    textbox "$tmp"
  fi
  rm -f "$tmp"
}


vnext_mark_known_good() {
  local repo="$1"
  local ts default_tag tag note msg tmp branch head

  ts="$(date +%Y%m%d-%H%M)"
  default_tag="gutt/known-good-$ts"

  branch="$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  head="$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo "?")"

  tag="$(inputbox "Mark current commit as known-good

Enter tag name:" "$default_tag")" || return 0
  tag="${tag## }"; tag="${tag%% }"

  if ! validate_tag_name "$tag"; then
    msgbox "Invalid tag name:

$tag"
    return 0
  fi

  note="$(inputbox "Optional note for this known-good tag (leave blank for none):" "")" || return 0
  note="${note## }"; note="${note%% }"

  msg="Known-good state marked by GUTT"$'
'"Branch: $branch"$'
'"Commit: $head"
  if [[ -n "$note" ]]; then
    msg="$msg"$'

'"Note: $note"
  fi

  tmp="$(mktemp_gutt)"
  (cd "$repo" && git tag -a "$tag" -m "$msg") >"$tmp" 2>&1 || true
  if git_tag_exists "$repo" "$tag"; then
    {
      echo "Created known-good tag:"
      echo
      echo "  Tag   : $tag"
      echo "  Branch: $branch"
      echo "  Commit: $head"
      echo
    } >"$tmp"
    textbox "$tmp"
  else
    textbox "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"

  if have_origin_remote "$repo"; then
    if whiptail --title "$APP_NAME $VERSION" --yesno --defaultno \
      "Push this tag to origin now?

Tag: $tag" 12 78 3>&1 1>&2 2>&3; then
      run_git_capture "$repo" git push origin "$tag"
    fi
  else
    msgbox "No origin remote found.

Tag was created locally only."
  fi
}


vnext_delete_local_tag() {
  local repo="$1"
  local tag token tmp branch last

  vnext_list_tags "$repo"

  tag="$(inputbox "Delete LOCAL tag (guarded)\n\nEnter tag name to delete:" "")" || return 0
  tag="${tag## }"; tag="${tag%% }"

  if [[ -z "$tag" ]]; then
    return 0
  fi

  if ! git_tag_exists "$repo" "$tag"; then
    msgbox "Tag not found locally:\n\n$tag"
    return 0
  fi

  branch="$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  last="$(cd "$repo" && git log -1 --oneline 2>/dev/null || echo "?")"

  offer_backup_tag "$repo"

  token="$(inputbox "About to DELETE LOCAL tag:\n\n$tag\n\nRepo branch: $branch\nLast commit: $last\n\nType DELETE to confirm:" "")" || return 0
  if [[ "$token" != "DELETE" ]]; then
    msgbox "Cancelled."
    return 0
  fi

  tmp="$(mktemp_gutt)"
  (cd "$repo" && git tag -d "$tag") >"$tmp" 2>&1 || true
  textbox "$tmp"
  rm -f "$tmp"
}


vnext_push_tag_to_origin() {
  local repo="$1"
  local tag

  if ! have_origin_remote "$repo"; then
    msgbox "No origin remote found."
    return 0
  fi

  vnext_list_tags "$repo"

  tag="$(inputbox "Push tag to origin\n\nEnter tag name to push:" "")" || return 0
  tag="${tag## }"; tag="${tag%% }"

  if [[ -z "$tag" ]]; then
    return 0
  fi

  if ! git_tag_exists "$repo" "$tag"; then
    msgbox "Tag not found locally:\n\n$tag"
    return 0
  fi

  run_git_capture "$repo" git push origin "$tag"
}


vnext_push_all_tags() {
  local repo="$1"
  local token

  if ! have_origin_remote "$repo"; then
    msgbox "No origin remote found."
    return 0
  fi

  token="$(inputbox "Push ALL tags to origin (guarded)\n\nThis will push every local tag.\n\nType PUSHALL to confirm:" "")" || return 0
  if [[ "$token" != "PUSHALL" ]]; then
    msgbox "Cancelled."
    return 0
  fi

  run_git_capture "$repo" git push --tags
}


vnext_push_current_branch() {
  local repo="$1"
  local branch upstream remote cmd

  branch="$(git_current_branch "$repo")"
  if [[ -z "$branch" ]]; then
    msgbox "Not a git repo (or cannot read current branch)."
    return 1
  fi
  if [[ "$branch" == "HEAD" ]]; then
    msgbox "Cannot push from a detached HEAD.\n\nCheck out a branch first."
    return 1
  fi

  upstream="$(git_upstream "$repo")"

  if [[ -n "$upstream" ]]; then
    if ! yesno "Push current branch now?\n\nBranch: $branch\nUpstream: $upstream\n\nThis will run:\n  git push\n\nProceed?"; then
      msgbox "Cancelled."
      return 0
    fi
    cmd=(git push)
  else
    # Prefer origin if present, else fall back to the first remote.
    if (cd "$repo" && git remote 2>/dev/null | grep -qx "origin"); then
      remote="origin"
    else
      remote="$(cd "$repo" && git remote 2>/dev/null | head -n1 || true)"
    fi

    if [[ -z "$remote" ]]; then
      msgbox "No remotes found.\n\nAdd a remote first (for example: origin)."
      return 1
    fi

    if ! yesno "No upstream is set for this branch.\n\nBranch: $branch\nUpstream: (none)\n\nSet upstream to:\n  ${remote}/${branch}\n\nand push now?\n\nThis will run:\n  git push -u $remote $branch\n\nProceed?"; then
      msgbox "Cancelled."
      return 0
    fi

    cmd=(git push -u "$remote" "$branch")
  fi

  # Optional fetch first (safer push feedback).
  if [[ "$(cfg_get auto_fetch_before_push 1)" == "1" ]]; then
    local tmpf rc
    tmpf="$(mktemp_gutt)"
    (cd "$repo" && git fetch --all --prune) >"$tmpf" 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
      textbox "$tmpf"
      rm -f "$tmpf"
      msgbox "Fetch failed. Push aborted."
      return $rc
    fi
    rm -f "$tmpf"
  fi

  local tmpp rc
  tmpp="$(mktemp_gutt)"
  (cd "$repo" && "${cmd[@]}") >"$tmpp" 2>&1
  rc=$?
  textbox "$tmpp"
  rm -f "$tmpp"

  if [[ $rc -eq 0 ]]; then
    msgbox "Push completed successfully."
  else
    msgbox "Push failed.\n\nReview the output for details."
  fi
  return $rc
}


vnext_push_all_branches() {
  local repo="$1"
  local remote

  # Prefer origin if present, else fall back to the first remote.
  if (cd "$repo" && git remote 2>/dev/null | grep -qx "origin"); then
    remote="origin"
  else
    remote="$(cd "$repo" && git remote 2>/dev/null | head -n1 || true)"
  fi

  if [[ -z "$remote" ]]; then
    msgbox "No remotes found.\n\nAdd a remote first (for example: origin)."
    return 1
  fi

  if ! yesno "Push ALL local branches to '$remote'?\n\nThis is advanced and can create lots of remote branches.\n\nThis will run:\n  git push $remote --all\n\nProceed?"; then
    msgbox "Cancelled."
    return 0
  fi

  # Optional fetch first (consistency / feedback).
  if [[ "$(cfg_get auto_fetch_before_push 1)" == "1" ]]; then
    local tmpf rc
    tmpf="$(mktemp_gutt)"
    (cd "$repo" && git fetch --all --prune) >"$tmpf" 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
      textbox "$tmpf"
      rm -f "$tmpf"
      msgbox "Fetch failed. Push aborted."
      return $rc
    fi
    rm -f "$tmpf"
  fi

  local tmpp rc
  tmpp="$(mktemp_gutt)"
  (cd "$repo" && git push "$remote" --all) >"$tmpp" 2>&1
  rc=$?
  textbox "$tmpp"
  rm -f "$tmpp"

  if [[ $rc -eq 0 ]]; then
    msgbox "Push (all branches) completed successfully."
  else
    msgbox "Push (all branches) failed.\n\nReview the output for details."
  fi
  return $rc
}


vnext_squash_merge_into_main() {
  local repo="$1"
  local main branch tmp tmp2 logtmp msg rc

  refuse_if_dirty "$repo" "Squash merge into main" || return 1

  if git_is_detached "$repo"; then
    msgbox "Refusing to squash-merge.\n\nYou are in a detached HEAD state.\n\nCheckout a branch first."
    return 1
  fi

  branch="$(git_current_branch "$repo")"
  main="$(git_detect_main_branch "$repo")"

  if [[ -z "$branch" || -z "$main" ]]; then
    msgbox "Unable to determine current or main branch.\n\nCurrent: '$branch'\nMain: '$main'"
    return 1
  fi

  if [[ "$branch" == "$main" ]]; then
    msgbox "Refusing to squash-merge.\n\nYou are already on '$main'.\n\nSwitch to a feature branch first."
    return 1
  fi

  # Build a commit summary of what will be squashed
  logtmp="$(mktemp_gutt)"
  (cd "$repo" && git log --oneline --decorate "$main..$branch" 2>/dev/null) >"$logtmp" || true

  if [[ ! -s "$logtmp" ]]; then
    rm -f "$logtmp"
    msgbox "Nothing to squash-merge.\n\nNo commits found in:\n  $main..$branch"
    return 0
  fi

  tmp="$(mktemp_gutt)"
  {
    echo "About to SQUASH MERGE"
    echo
    echo "From branch: $branch"
    echo "Into main:   $main"
    echo
    echo "Commits to be squashed (most recent first):"
    echo "------------------------------------------"
    cat "$logtmp"
    echo
    echo "This will create ONE new commit on '$main'."
    echo
    echo "Preconditions enforced:"
    echo " - clean working tree"
    echo " - not detached HEAD"
    echo
    echo "If conflicts happen, you can abort with:"
    echo "  git merge --abort"
  } >"$tmp"

  textbox "$tmp"
  rm -f "$tmp"

  # Default NO for publish actions
  whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Proceed with squash merge of '$branch' into '$main'?" 12 78 3>&1 1>&2 2>&3 || {
    rm -f "$logtmp"
    return 0
  }

  # Optional smoke tests (default NO)
  if whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Run smoke tests BEFORE merging?" 12 78 3>&1 1>&2 2>&3; then
    tmp2="$(mktemp_gutt)"
    vnext_smoke_tests_internal "$repo" "$tmp2"
    rc=$?
    textbox "$tmp2"
    rm -f "$tmp2"
    if [[ $rc -ne 0 ]]; then
      whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Smoke tests FAILED.\n\nContinue with merge anyway?" 12 78 3>&1 1>&2 2>&3 || {
        rm -f "$logtmp"
        return 1
      }
    fi
  fi

  # Switch to main and pull safely (uses existing action)
  (cd "$repo" && git switch "$main" >/dev/null 2>&1) || (cd "$repo" && git checkout "$main" >/dev/null 2>&1) || {
    rm -f "$logtmp"
    msgbox "Failed to switch to '$main'."
    return 1
  }

  if ! action_pull_safe_update "$repo"; then
    rm -f "$logtmp"
    msgbox "Pull aborted.\n\n'$main' could not be fast-forwarded cleanly.\n\nResolve upstream changes manually, then retry."
    return 1
  fi

  # Mandatory local safety tag before the squash merge
  local ts tag
  ts="$(date +%Y%m%d-%H%M%S)"
  tag="gutt/safety-sqm-$ts"
  (cd "$repo" && git tag -f "$tag" >/dev/null 2>&1) || true
  msgbox "Created local safety tag:\n\n$tag\n\n(This stays local unless you push tags.)"

  # Perform the squash merge
  tmp2="$(mktemp_gutt)"
  (cd "$repo" && git merge --squash "$branch") >"$tmp2" 2>&1
  rc=$?

  if [[ -s "$tmp2" ]]; then
    textbox "$tmp2"
  fi
  rm -f "$tmp2"

  if [[ $rc -ne 0 ]]; then
    rm -f "$logtmp"
    msgbox "Squash merge FAILED (likely conflicts).\n\nRepo is now in a merge state.\n\nOptions:\n - Resolve conflicts, then commit\n - Or abort: git merge --abort"
    return 1
  fi

  # Commit message (guided)
  msg="$(inputbox "Enter the final squash commit message:" "Squash merge $branch")" || {
    rm -f "$logtmp"
    msgbox "Cancelled. Note: squash changes are still staged on '$main'.\n\nYou can commit manually, or abort with:\n  git reset --mixed"
    return 1
  }

  tmp2="$(mktemp_gutt)"
  (cd "$repo" && git commit -m "$msg") >"$tmp2" 2>&1
  rc=$?
  if [[ -s "$tmp2" ]]; then
    textbox "$tmp2"
  fi
  rm -f "$tmp2"

  if [[ $rc -ne 0 ]]; then
    rm -f "$logtmp"
    msgbox "Commit failed.\n\nYour squash merge changes should still be staged.\nFix the issue and commit manually."
    return 1
  fi

  # Optional cleanup: delete feature branch (default NO)
  if whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Delete local branch '$branch' now that it is merged?" 12 78 3>&1 1>&2 2>&3; then
    (cd "$repo" && git branch -d "$branch") >/dev/null 2>&1 || (cd "$repo" && git branch -D "$branch") >/dev/null 2>&1 || true
  fi

  # Optional push main (default NO)
  if whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Push '$main' to origin now?" 12 78 3>&1 1>&2 2>&3; then
    vnext_push_current_branch "$repo"
  fi

  rm -f "$logtmp"
  action_status "$repo"
}


vnext_smoke_tests_internal() {
  # Usage: vnext_smoke_tests_internal <repo> <out_file>
  # Returns: 0 pass, non-zero fail
  local repo="$1" out="$2"
  local script="" rc=0

  if [[ -x "$repo/scripts/smoke.sh" ]]; then
    script="./scripts/smoke.sh"
  elif [[ -x "$repo/smoke.sh" ]]; then
    script="./smoke.sh"
  elif [[ -x "$repo/test.sh" ]]; then
    script="./test.sh"
  fi

  if [[ -n "$script" ]]; then
    (cd "$repo" && bash "$script") >"$out" 2>&1
    return $?
  fi

  # Fallback: bash -n for shell scripts
  (cd "$repo" && find . -type f -name "*.sh" -not -path "./.git/*" -print0 | xargs -0 -r bash -n) >"$out" 2>&1
  rc=$?

  if [[ ! -s "$out" ]]; then
    echo "No smoke script found, and no shell scripts to syntax-check." >"$out"
    rc=0
  fi

  return $rc
}


vnext_delete_branch() {
  local repo="$1"

  if git_has_changes "$repo"; then
    msgbox "Refusing while repo has uncommitted changes.\n\nCommit or stash first."
    return 1
  fi

  local b cur main
  b="$(pick_branch "$repo")" || return 0
  cur="$(git_current_branch "$repo")"
  main="$(git_detect_main_branch "$repo")"

  if [[ -n "$b" && "$b" == "$cur" ]]; then
    msgbox "Refusing to delete the currently checked-out branch."
    return 1
  fi

  if [[ -n "$b" && -n "$main" && "$b" == "$main" ]]; then
    msgbox "Refusing to delete the primary branch ($main).\n\nMain is sacred."
    return 1
  fi

  confirm_phrase "Delete local branch:\n\n$b\n\nThis removes the branch name, not your commits (they may still exist via other refs).\n\nProceed?" "DELETE BRANCH" || { msgbox "Cancelled."; return 0; }
  run_git_capture "$repo" git branch -d "$b"
}


vnext_prune_remote_tracking() {
  local repo="$1"

  local remote
  if (cd "$repo" && git remote | grep -qx "origin"); then
    remote="origin"
  else
    remote="$(pick_remote "$repo")" || { msgbox "No remotes found."; return 0; }
  fi

  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git remote prune "$remote" --dry-run) >"$tmp" 2>&1 || true

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    msgbox "No remote-tracking references to prune for '$remote'."
    return 0
  fi

  textbox "$tmp"
  rm -f "$tmp"

  confirm_phrase "About to PRUNE remote-tracking branches for:\n\n$remote\n\nThis removes stale local refs like:\n  $remote/<branch>\n\nIt does NOT delete branches on the remote.\n\nProceed?" "PRUNE" || { msgbox "Cancelled."; return 0; }

  run_git_capture "$repo" git remote prune "$remote"
}


vnext_upstream_tracking() {
  local repo="$1"

  local cur
  cur="$(git_current_branch "$repo")"
  if [[ -z "$cur" || "$cur" == "DETACHED" || "$cur" == "HEAD" ]]; then
    msgbox "Refusing: not on a normal branch (detached HEAD).\n\nCheckout a branch first."
    return 1
  fi

  while true; do
    local upstream
    upstream="$(git_upstream "$repo")"
    [[ -n "$upstream" ]] || upstream="(none)"

    local choice
    choice="$(menu "$APP_NAME $VERSION" "Upstream tracking (current branch)

Repo:
$repo

Branch:
$cur

Upstream:
$upstream" \
      "VIEW" "View upstream status (safe)" \
      "SET"  "Set or change upstream (guarded)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      VIEW)
        # A compact, useful view that includes upstream + ahead/behind when available.
        run_git_capture "$repo" git status -sb
        ;;
      SET)
        local remote target
        remote=""
        if have_origin_remote "$repo"; then
          remote="origin"
        else
          remote="$(pick_remote "$repo")" || { msgbox "No remotes found."; continue; }
        fi

        # Try the most common convention first: <remote>/<current-branch>
        target="$remote/$cur"

        # If the guessed remote branch doesn't exist, offer a picker from that remote.
        if ! (cd "$repo" && git show-ref --verify --quiet "refs/remotes/$remote/$cur"); then
          local tmp items=() rb
          tmp="$(mktemp_gutt)"
          (cd "$repo" && git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$remote" 2>/dev/null | grep -v '^HEAD$') >"$tmp" || true
          if [[ ! -s "$tmp" ]]; then
            rm -f "$tmp"
            msgbox "No remote branches found under '$remote'.\n\nYou may need to fetch first."
            continue
          fi

          while IFS= read -r rb; do
            [[ -n "$rb" ]] || continue
            items+=("$rb" "")
          done <"$tmp"
          rm -f "$tmp"

          local rc=0 had_e=0
          [[ $- == *e* ]] && had_e=1
          set +e
          rb="$(whiptail --title "$APP_NAME $VERSION" --menu "Select remote branch for upstream ($remote)" 20 78 12 "${items[@]}" 3>&1 1>&2 2>&3)"
          rc=$?
          ((had_e)) && set -e
          [[ $rc -eq 0 ]] || continue
          target="$remote/$rb"
        fi

        # Allow manual override (still validated by git on set).
        target="$(inputbox "Upstream ref to set for '$cur'\n\nExamples:\n  $remote/$cur\n  $remote/feature/foo\n" "$target")" || continue
        [[ -n "$target" ]] || continue

        if ! whiptail --title "$APP_NAME $VERSION" --yesno --defaultno \
          "Set upstream for:\n  $cur\n\nto:\n  $target\n\nThis is guarded and only affects tracking config.\nProceed?" 15 78 3>&1 1>&2 2>&3; then
          continue
        fi

        if ! confirm_phrase "Type exactly to confirm:\n\nSET UPSTREAM" "SET UPSTREAM"; then
          msgbox "Cancelled."
          continue
        fi

        run_git_capture "$repo" git branch --set-upstream-to="$target" "$cur"
        ;;
      BACK) return 0 ;;
    esac
  done
}


vnext_rename_current_branch() {
  local repo="$1"
  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }

  local cur main
  cur="$(git_current_branch "$repo")"
  main="$(git_detect_main_branch "$repo")"

  if [[ -n "$cur" && "$cur" == "$main" ]]; then
    msgbox "Refusing to rename the primary branch ($main).\n\nMain is sacred.\n\nTip: create and switch to a feature branch first."
    return 1
  fi

  action_branch_rename "$repo"
}


vnext_create_branch() {
  local repo="$1"
  local name
  name="$(inputbox "New branch name (local)" "")" || return 0
  [[ -n "$name" ]] || return 0

  if ! (cd "$repo" 2>/dev/null && git check-ref-format --branch "$name" >/dev/null 2>&1); then
    msgbox "Invalid branch name:\n\n$name"
    return 0
  fi

  if (cd "$repo" 2>/dev/null && git show-ref --verify --quiet "refs/heads/$name"); then
    msgbox "Branch already exists:\n\n$name"
    return 0
  fi

  run_git_capture "$repo" git branch "$name"
}


vnext_list_branches() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"

  (
    cd "$repo" 2>/dev/null || exit 0

    cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

    echo "Branches"
    echo "========"
    echo
    if [[ -n "$cur" ]]; then
      echo "Current branch: $cur"
    else
      echo "Current branch: (detached HEAD or unknown)"
    fi

    up="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
    if [[ -n "$up" ]]; then
      echo "Upstream       : $up"
    else
      echo "Upstream       : (none set)"
    fi
    echo

    echo "Local branches"
    echo "--------------"
    if [[ -n "$(git for-each-ref --count=1 refs/heads 2>/dev/null || true)" ]]; then
      git for-each-ref refs/heads --sort=refname         --format='%(refname:short)|%(upstream:short)|%(objectname:short)|%(committerdate:relative)|%(subject)' 2>/dev/null       | while IFS='|' read -r name upstream sha rel subj; do
          mark=" "
          if [[ -n "$cur" && "$name" == "$cur" ]]; then
            mark="*"
          fi

          if [[ -n "$upstream" ]]; then
            printf "%s %-28s  %s  %s  -  %s  (upstream: %s)
" "$mark" "$name" "${sha:0:8}" "$rel" "$subj" "$upstream"
          else
            printf "%s %-28s  %s  %s  -  %s
" "$mark" "$name" "${sha:0:8}" "$rel" "$subj"
          fi
        done
    else
      echo "(no local branches found)"
    fi

    echo
    echo "Remote branches"
    echo "---------------"
    if [[ -n "$(git for-each-ref --count=1 refs/remotes 2>/dev/null || true)" ]]; then
      git for-each-ref refs/remotes --sort=refname         --format='%(refname:short)|%(objectname:short)|%(committerdate:relative)|%(subject)' 2>/dev/null       | grep -vE '(^|/)HEAD$'       | while IFS='|' read -r name sha rel subj; do
          printf "  %-30s  %s  %s  -  %s
" "$name" "${sha:0:8}" "$rel" "$subj"
        done
    else
      echo "(no remote branches found)"
    fi

    echo
    echo "Notes"
    echo "-----"
    echo "- '*' marks the current branch."
    echo "- 'upstream' shown where tracking is configured."
  ) >"$tmp" 2>&1 || true

  textbox "$tmp"
  rm -f "$tmp"
}


vnext_remote_info() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  (
    cd "$repo" 2>/dev/null || exit 0

    echo "Remote info"
    echo "==========="
    echo
    echo "Remotes (git remote -v):"
    git remote -v 2>/dev/null || true
    echo

    for r in origin upstream; do
      if git remote get-url "$r" >/dev/null 2>&1; then
        echo "$r:"
        echo "  fetch: $(git remote get-url "$r" 2>/dev/null || true)"
        if git remote get-url --push "$r" >/dev/null 2>&1; then
          echo "  push : $(git remote get-url --push "$r" 2>/dev/null || true)"
        fi
        echo
      fi
    done

    echo "Current branch + tracking:"
    br="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")"
    echo "  branch: $br"

    up="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
    if [[ -n "$up" ]]; then
      echo "  upstream: $up"
      ab="$(git rev-list --left-right --count HEAD...@{u} 2>/dev/null || true)"
      if [[ -n "$ab" ]]; then
        ahead="${ab%% *}"
        behind="${ab##* }"
        echo "  ahead/behind: ahead $ahead, behind $behind"
      fi
    else
      echo "  upstream: (none)"
    fi
    echo

    echo "Branch summary (git branch -vv):"
    git branch -vv 2>/dev/null || true
  ) >"$tmp" 2>&1 || true

  textbox "$tmp"
  rm -f "$tmp"
}


vnext_ahead_behind() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  (
    cd "$repo" 2>/dev/null || exit 0

    echo "Ahead / Behind (upstream)"
    echo "========================"
    echo

    local br up ab ahead behind
    br="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")"
    echo "branch   : $br"

    up="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
    if [[ -z "$up" ]]; then
      echo "upstream : (none)"
      echo
      echo "Tip: set an upstream with:"
      echo "  git branch --set-upstream-to origin/$br"
      exit 0
    fi

    echo "upstream : $up"

    ab="$(git rev-list --left-right --count HEAD...@{u} 2>/dev/null || true)"
    if [[ -n "$ab" ]]; then
      ahead="${ab%% *}"
      behind="${ab##* }"
      echo "ahead    : $ahead"
      echo "behind   : $behind"
    else
      echo "ahead    : ?"
      echo "behind   : ?"
    fi

    echo
    echo "Summary (git status -sb):"
    git status -sb 2>/dev/null || true
  ) >"$tmp" 2>/dev/null || true

  textbox "$APP_NAME $VERSION" "$tmp"
  rm -f "$tmp"
}


vnext_branch_last_commit_details() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  (
    cd "$repo" 2>/dev/null || exit 0

    echo "Current branch + last commit details"
    echo "==================================="
    echo

    local br up
    br="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")"
    echo "branch   : $br"

    up="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
    if [[ -n "$up" ]]; then
      echo "upstream : $up"
    else
      echo "upstream : (none)"
    fi
    echo

    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
      echo "(no commits yet)"
      exit 0
    fi

    echo "Last commit (fuller):"
    echo "---------------------"
    git show -s --format=fuller HEAD 2>/dev/null || true
    echo

    echo "Files changed (stat):"
    echo "---------------------"
    git show --stat -1 --oneline HEAD 2>/dev/null || true
  ) >"$tmp"

  textbox "Branch + last commit" "$tmp"
  rm -f "$tmp"
}


vnext_repo_details() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  (
    cd "$repo" 2>/dev/null || exit 0

    echo "Repo details"
    echo "==========="
    echo

    local top gitdir inside bare br
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    gitdir="$(git rev-parse --git-dir 2>/dev/null || true)"
    inside="$(git rev-parse --is-inside-work-tree 2>/dev/null || true)"
    bare="$(git rev-parse --is-bare-repository 2>/dev/null || true)"

    echo "Paths:"
    echo "  top-level : ${top:-"(unknown)"}"
    echo "  .git dir  : ${gitdir:-"(unknown)"}"
    echo

    echo "Repo type:"
    echo "  inside work tree : ${inside:-"(unknown)"}"
    echo "  bare repository  : ${bare:-"(unknown)"}"
    echo

    echo "Origin default branch (if available):"
    if git remote get-url origin >/dev/null 2>&1; then
      local head_branch remote_head
      head_branch="$(git remote show origin 2>/dev/null | sed -n 's/^  HEAD branch: //p' | head -n 1)"
      remote_head="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      echo "  HEAD branch (remote show): ${head_branch:-"(unknown)"}"
      echo "  origin/HEAD (symbolic)    : ${remote_head:-"(not set)"}"
    else
      echo "  origin remote not set."
    fi
    echo

    echo "Current HEAD:"
    br="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo "(detached)")"
    echo "  branch : $br"
    echo "  commit : $(git rev-parse --short HEAD 2>/dev/null || echo "(no commits)")"
    echo

    echo "Remotes:"
    git remote -v 2>/dev/null || echo "  (none)"
    echo

  ) >"$tmp"

  textbox "$APP_NAME $VERSION" "$tmp"
  rm -f "$tmp"
}


vnext_untracked_summary() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  (
    cd "$repo" 2>/dev/null || exit 0

    echo "Untracked / ignored summary"
    echo "==========================="
    echo

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo "Not a git repository."
      exit 0
    fi

    # Untracked files (respects .gitignore)
    local untracked_total=0
    local show_limit=200
    mapfile -t _untracked < <(git ls-files --others --exclude-standard 2>/dev/null || true)
    untracked_total="${#_untracked[@]}"

    echo "Untracked files (git ls-files --others --exclude-standard):"
    if (( untracked_total == 0 )); then
      echo "  (none)"
    else
      local i=0
      for f in "${_untracked[@]}"; do
        printf "  %s\n" "$f"
        ((i++))
        (( i >= show_limit )) && break
      done
      if (( untracked_total > show_limit )); then
        echo "  ... ($((untracked_total - show_limit)) more)"
      fi
    fi
    echo

    # Ignored files (matching only)
    local ignored_total=0
    mapfile -t _ignored < <(git status --porcelain=v1 --ignored=matching 2>/dev/null | awk 'substr($0,1,2)=="!!"{print substr($0,4)}' || true)
    ignored_total="${#_ignored[@]}"

    echo "Ignored files (git status --porcelain --ignored=matching):"
    if (( ignored_total == 0 )); then
      echo "  (none)"
    else
      local j=0
      for f in "${_ignored[@]}"; do
        printf "  %s\n" "$f"
        ((j++))
        (( j >= show_limit )) && break
      done
      if (( ignored_total > show_limit )); then
        echo "  ... ($((ignored_total - show_limit)) more)"
      fi
    fi
    echo

    echo "Counts:"
    echo "  Untracked: $untracked_total"
    echo "  Ignored  : $ignored_total"
    echo
    echo "Note: cleanup tools live under Hygiene & Cleanup (guarded where destructive)."
  ) >"$tmp"

  textbox "$tmp"
  rm -f "$tmp"
}


vnext_upstream_health_view() {
  local repo="$1"
  local tmp branch upstream origin_url ab ahead behind

  tmp="$(mktemp_gutt)"

  branch="$(git_current_branch "$repo")"
  upstream="$(git_upstream "$repo")"

  if have_origin_remote "$repo"; then
    origin_url="$(cd "$repo" && git remote get-url origin 2>/dev/null || true)"
  else
    origin_url=""
  fi

  ahead="?"
  behind="?"
  if [[ -n "$upstream" ]]; then
    ab="$(cd "$repo" && git rev-list --left-right --count "HEAD...@{u}" 2>/dev/null || true)"
    ahead="${ab%% *}"
    behind="${ab##* }"
    [[ -z "$ahead" ]] && ahead="0"
    [[ -z "$behind" ]] && behind="0"
  fi

  {
    printf '%s\n' "Upstream health (read-only)"
    printf '%s\n' "Repo: $repo"
    printf '\n'

    printf '%s\n' "== Remotes =="
    if [[ -n "$origin_url" ]]; then
      printf 'origin: %s\n' "$origin_url"
    else
      printf '%s\n' "origin: (not set)"
    fi
    printf '\n'

    printf '%s\n' "== Branch / upstream =="
    if git_is_detached "$repo"; then
      printf '%s\n' "HEAD state: detached"
    else
      printf 'Branch: %s\n' "${branch:-unknown}"
    fi

    if [[ -n "$upstream" ]]; then
      printf 'Upstream: %s\n' "$upstream"
      printf 'Ahead/Behind: %s ahead, %s behind\n' "$ahead" "$behind"
    else
      printf '%s\n' "Upstream: (none set)"
      printf '%s\n' "Ahead/Behind: (n/a)"
      printf '\n'
      printf '%s\n' "Tip: Use 'Set / view upstream' to connect this branch to origin."
    fi

    printf '\n'
    printf '%s\n' "Notes:"
    printf '%s\n' "- This view is read-only."
    printf '%s\n' "- Ahead/Behind uses your configured upstream (@{u})."
  } >"$tmp"

  textbox "$tmp" || true
  rm -f "$tmp"
}


vnext_hygiene_cleanup_summary() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"

  # Keep it fast and safe: show counts + samples, and only size common junk folders.
  local untracked_count ignored_count
  untracked_count="$(cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || true)"
  ignored_count="$(cd "$repo" && git ls-files --others -i --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || true)"

  {
    printf '%s\n' "Hygiene & Cleanup summary (read-only)"
    printf '%s\n' "Repo: $repo"
    printf '%s\n' ""

    printf '%s\n' "== Untracked files =="
    printf 'Count: %s\n' "${untracked_count:-0}"
    printf '%s\n' "Sample (up to 60):"
    (cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | head -n 60) || true
    printf '%s\n' ""

    printf '%s\n' "== Ignored files (per .gitignore etc) =="
    printf 'Count: %s\n' "${ignored_count:-0}"
    printf '%s\n' "Sample (up to 60):"
    (cd "$repo" && git ls-files --others -i --exclude-standard 2>/dev/null | head -n 60) || true
    printf '%s\n' ""

    printf '%s\n' "== Common junk folders (detected) =="
    printf '%s\n' "Searched up to depth 4 (excluding .git). Sizes via du -sh."
    printf '%s\n' ""

    local found_any=0
    local name
    for name in node_modules dist build out __pycache__ .pytest_cache .mypy_cache .tox .venv venv .cache coverage .next .nuxt target vendor .terraform; do
      # Find matching dirs (limit depth for performance)
      while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        found_any=1
        local sz
        sz="$(cd "$repo" && du -sh "$path" 2>/dev/null | awk '{print $1}' || true)"
        printf '%-10s %s\n' "${sz:--}" "$path"
      done < <(cd "$repo" && find . -maxdepth 4 -path './.git' -prune -o -type d -name "$name" -print 2>/dev/null | head -n 40)
    done

    if [[ "$found_any" -eq 0 ]]; then
      printf '%s\n' "(none of the common junk folders were found in the first 4 levels)"
    fi

    printf '%s\n' ""
    printf '%s\n' "Notes:"
    printf '%s\n' "- This is Phase 10.1 and does not change anything."
    printf '%s\n' "- Later phases can add guarded cleanup actions (default NO), one at a time."
  } >"$tmp"

  textbox "$tmp"
  rm -f "$tmp"
}


vnext_hygiene_export_report() {
  local repo="$1"
  local dest default_dest ts
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || true)"
  default_dest="/tmp/gutt-hygiene-${ts:-report}.txt"

  dest="$(inputbox "Export hygiene report\n\nThis is read-only and writes a report file.\n\nEnter output path:" "$default_dest")" || return 0

  # Basic sanity: refuse empty
  if [[ -z "${dest// }" ]]; then
    msgbox "No output path provided."
    return 0
  fi

  # Build report (similar to 10.1 summary, with slightly larger samples).
  local untracked_count ignored_count
  untracked_count="$(cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || true)"
  ignored_count="$(cd "$repo" && git ls-files --others -i --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || true)"

  {
    printf '%s\n' "GUTT Hygiene report (Phase 10.2 export)"
    printf '%s\n' "Generated: $(date -R 2>/dev/null || date 2>/dev/null || true)"
    printf '%s\n' "Repo: $repo"
    printf '%s\n' ""

    printf '%s\n' "== Untracked files =="
    printf 'Count: %s\n' "${untracked_count:-0}"
    printf '%s\n' "Sample (up to 500):"
    (cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | head -n 500) || true
    printf '%s\n' ""

    printf '%s\n' "== Ignored files (per .gitignore etc) =="
    printf 'Count: %s\n' "${ignored_count:-0}"
    printf '%s\n' "Sample (up to 500):"
    (cd "$repo" && git ls-files --others -i --exclude-standard 2>/dev/null | head -n 500) || true
    printf '%s\n' ""

    printf '%s\n' "== Common junk folders (depth <= 4, excluding .git) =="
    printf '%s\n' "Size shown via du -sh for each folder found."
    printf '%s\n' ""

    local -a junk_names
    junk_names=(
      "node_modules"
      "dist"
      "build"
      "__pycache__"
      ".pytest_cache"
      ".mypy_cache"
      ".ruff_cache"
      ".venv"
      "venv"
      ".tox"
      ".cache"
      ".DS_Store"
      "coverage"
      ".coverage"
    )

    local found_any=0
    local name d
    for name in "${junk_names[@]}"; do
      while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        found_any=1
        # du can be slow; keep it limited and safe.
        (cd "$repo" && du -sh "$d" 2>/dev/null) || printf '%s\n' "(size unavailable) $d"
      done < <(cd "$repo" && find . -path "./.git" -prune -o -maxdepth 4 -type d -name "$name" -print 2>/dev/null | sed 's|^\./||' || true)
    done

    if [[ "$found_any" -eq 0 ]]; then
      printf '%s\n' "(none of the common junk folders were found in the first 4 levels)"
    fi

    printf '%s\n' ""
    printf '%s\n' "Notes:"
    printf '%s\n' "- Export is non-destructive; it only writes this report file."
    printf '%s\n' "- Cleanup actions (if/when added) must be guarded and default NO."
  } >"$dest" 2>/dev/null || {
    msgbox "Failed to write report:\n\n$dest"
    return 0
  }

  if yesno "Report written:\n\n$dest\n\nOpen it now?" ; then
    textbox "$dest"
  else
    msgbox "Done.\n\nReport saved to:\n$dest"
  fi
}


vnext_hygiene_restore_files() {
  local repo="$1"

  # Build candidate list: tracked files with unstaged changes (worktree changes).
  local porcelain
  porcelain="$(cd "$repo" && git status --porcelain=v1 2>/dev/null || true)"

  local items=()
  local count=0
  local line x y path st

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    # Skip untracked; git restore won't help there.
    if [[ "${line:0:2}" == "??" ]]; then
      continue
    fi

    x="${line:0:1}"
    y="${line:1:1}"

    # We are restoring the working tree only. If there's no worktree change, skip.
    [[ "$y" != " " ]] || continue

    st="${line:0:2}"
    path="${line:3}"

    # Handle rename display: "old -> new" (use new path).
    if [[ "$path" == *" -> "* ]]; then
      path="${path##* -> }"
    fi

    # Trim any surrounding whitespace
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    [[ -n "$path" ]] || continue

    items+=("$path" "$st" "OFF")
    ((count++))

    # Hard cap to keep UI responsive.
    if (( count >= 400 )); then
      break
    fi
  done <<<"$porcelain"

  if (( count == 0 )); then
    msgbox "No tracked files with unstaged changes were found.\n\nTip:\n- Untracked files (??) are not restored by git restore.\n- Staged-only changes won't appear here because there are no working-tree edits."
    return 0
  fi

  local selected rc=0 had_e=0
  [[ $- == *e* ]] && had_e=1
  set +e
  selected="$(whiptail --title "$APP_NAME $VERSION" --separate-output --checklist "Restore file(s) (discard UNSTAGED changes)\n\nThis will run:\n  git restore -- <paths>\n\nMeaning (plain English):\n- Your working copy for those files will be reset back to the INDEX (the last staged version).\n- Any STAGED changes remain staged.\n- Untracked files are unaffected.\n\nSelect file(s) to restore:" 22 95 14 "${items[@]}" 3>&1 1>&2 2>&3)"
  rc=$?
  ((had_e)) && set -e
  [[ $rc -eq 0 ]] || return 0

  [[ -n "${selected//$'\n'/}" ]] || { msgbox "Nothing selected."; return 0; }
  local -a paths=()
  mapfile -t paths <<<"$selected"

  local summary
  summary=$(
    printf '%s\n' "You are about to discard UNSTAGED changes in your working copy for:"
    printf '%s\n' ""
    for p in "${paths[@]}"; do
      printf '  - %s\n' "$p"
    done
    printf '%s\n' ""
    printf '%s\n' "This will run:"
    printf '  git restore -- %s\n' "$(printf '%q ' "${paths[@]}")"
    printf '%s\n' ""
    printf '%s\n' "Proceed?"
  )

  if whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "$summary" 22 95 3>&1 1>&2 2>&3; then
    offer_backup_tag "$repo"
    (cd "$repo" && git restore -- "${paths[@]}") || true
    msgbox "Restore complete.\n\nTip:\n- If you need to undo STAGED changes, use the staging menu (unstage or discard) or wait for the staged-restore helper phase."
  else
    msgbox "Cancelled."
  fi
}


vnext_hygiene_clean_untracked() {
  local repo="$1"

  local preview tmp_out
  preview="$(mktemp_gutt)"
  tmp_out="$(mktemp_gutt)"

  {
    printf '%s\n' "GUTT: Clean untracked (guarded)"
    printf '%s\n' "Repo: $repo"
    printf '%s\n' ""
    printf '%s\n' "Preview only (no changes yet). This is what git clean would remove:"
    printf '%s\n' ""
    (cd "$repo" && git clean -nd 2>/dev/null) || true
  } >"$preview"

  # If there's nothing to clean, git clean prints nothing.
  if ! grep -qE '^(Would remove |Would skip repository )' "$preview"; then
    msgbox "Nothing to clean.\n\nNo untracked files/dirs were listed by:\n  git clean -nd"
    rm -f "$preview" "$tmp_out"
    return 0
  fi

  textbox "$preview" || true

  if ! yesno "About to permanently DELETE untracked files/dirs listed in the preview.\n\nThis will run:\n  git clean -fd\n\nNotes:\n- This does NOT touch tracked files.\n- This does NOT remove ignored files (unless you later add -x).\n- This cannot be undone.\n\nProceed?"; then
    rm -f "$preview" "$tmp_out"
    msgbox "Cancelled."
    return 0
  fi

  offer_backup_tag "$repo"

  if ! confirm_phrase "Final confirmation required.\n\nType CLEAN to permanently delete the untracked items shown in the preview." "CLEAN"; then
    rm -f "$preview" "$tmp_out"
    msgbox "Cancelled."
    return 0
  fi

  {
    printf '%s\n' "git clean output:"
    printf '%s\n' ""
    (cd "$repo" && git clean -fd 2>&1) || true
  } >"$tmp_out"

  textbox "$tmp_out" || msgbox "Clean complete."

  rm -f "$preview" "$tmp_out"
}


vnext_show_known_good_tags() {
  local repo="$1"
  local head tags
  head="$(cd "$repo" && git rev-parse HEAD 2>/dev/null || true)"
  tags="$(cd "$repo" && git tag --list 'gutt/known-good-*' 2>/dev/null || true)"

  if [[ -z "$tags" ]]; then
    msgbox "Known-good tags" "No known-good tags found.

Expected pattern: gutt/known-good-*"
    return 0
  fi

  local tmp
  tmp="$(mktemp_gutt)"
  {
    printf '%s\n' "Known-good tags (most recent first)"
    printf '%s\n' "Pattern: gutt/known-good-*"
    printf '%s\n' ""
    printf '%-34s %-10s %-12s %-5s %s\n' "TAG" "COMMIT" "DATE" "HEAD" "SUBJECT"
    printf '%s\n' "--------------------------------------------------------------------------------"
    local tag commit date subj headmark
    # Sort by commit date (newest first)
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      commit="$(cd "$repo" && git rev-parse "${tag}^{commit}" 2>/dev/null || true)"
      date="$(cd "$repo" && git show -s --format='%ad' --date=short "$tag" 2>/dev/null || true)"
      subj="$(cd "$repo" && git show -s --format='%s' "$tag" 2>/dev/null || true)"
      headmark="no"
      [[ -n "$head" && -n "$commit" && "$commit" == "$head" ]] && headmark="YES"
      printf '%-34s %-10s %-12s %-5s %s\n' "$tag" "${commit:0:8}" "$date" "$headmark" "$subj"
    done < <(cd "$repo" && git tag --list 'gutt/known-good-*' --sort=-creatordate 2>/dev/null || true)
    printf '%s\n' ""
    printf '%s\n' "Tip: If you need to recover, Phase 9.3 will guide you to a known-good tag safely."
  } >"$tmp"
  textbox "$tmp"
  rm -f "$tmp"
}


vnext_show_recovery_checklist() {
  local repo="$1"

  local branch detached dirty upstream ahead behind stash_count
  branch="$(git_current_branch "$repo")"
  detached="no"
  [[ "$branch" == "HEAD" || -z "$branch" ]] && detached="YES"

  dirty="no"
  git_has_changes "$repo" && dirty="YES"

  stash_count="$(cd "$repo" && git stash list 2>/dev/null | wc -l | tr -d ' ' || true)"
  upstream="$(cd "$repo" && git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"

  ahead="?"
  behind="?"
  if [[ -n "$upstream" ]]; then
    local counts
    counts="$(cd "$repo" && git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null || true)"
    behind="${counts%% *}"
    ahead="${counts##* }"
  fi

  local tmp
  tmp="$(mktemp_gutt)"
  {
    printf '%s\n' "Recovery checklist (read-only)"
    printf '%s\n' ""
    printf '%s\n' "1) Where am I?"
    printf '   - Branch: %s\n' "${branch:-unknown}"
    printf '   - Detached HEAD: %s\n' "$detached"
    printf '%s\n' ""
    printf '%s\n' "2) Is my working tree clean?"
    printf '   - Uncommitted changes: %s\n' "$dirty"
    printf '%s\n' ""
    printf '%s\n' "3) Do I have anything stashed?"
    printf '   - Stash entries: %s\n' "${stash_count:-0}"
    printf '%s\n' ""
    printf '%s\n' "4) Is upstream set and am I ahead/behind?"
    if [[ -n "$upstream" ]]; then
      printf '   - Upstream: %s\n' "$upstream"
      printf '   - Behind:   %s\n' "$behind"
      printf '   - Ahead:    %s\n' "$ahead"
    else
      printf '%s\n' "   - Upstream: (none set)"
      printf '%s\n' "   - Tip: set upstream before doing sync operations."
    fi
    printf '%s\n' ""
    printf '%s\n' "Suggested safe sequence (human steps):"
    printf '%s\n' "  A) git status -sb"
    printf '%s\n' "  B) If dirty: decide whether to commit, stash, or discard"
    printf '%s\n' "  C) Fetch first, then review ahead/behind"
    printf '%s\n' "  D) Only then consider recovery actions (known-good tag, new branch, etc.)"
    printf '%s\n' ""
    printf '%s\n' "Notes:"
    printf '%s\n' "- This view does not change anything."
    printf '%s\n' "- Phase 9.3 offers a guided known-good tag checkout flow (guarded, default NO)."
  } >"$tmp"
  textbox "$tmp"
  rm -f "$tmp"
}


vnext_show_emergency_revert_notes() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  {
    printf '%s\n' "Emergency notes (read-only)"
    printf '%s\n' ""
    printf '%s\n' "Last 20 commits:"
    printf '%s\n' ""
    (cd "$repo" && git --no-pager log -20 --oneline --decorate 2>/dev/null) || true
    printf '%s\n' ""
    printf '%s\n' "Safe options (human steps):"
    printf '%s\n' "- If a bad commit is already shared/pushed: prefer 'git revert <hash>' (creates a new commit)."
    printf '%s\n' "- If you just need to inspect history: use 'git reflog' to find previous states."
    printf '%s\n' "- Avoid 'reset --hard' unless you *really* know what you’re doing (destructive)."
    printf '%s\n' ""
    printf '%s\n' "Tip: Phase 9.3 also offers a guided known-good tag checkout path."
  } >"$tmp"
  textbox "$tmp"
  rm -f "$tmp"
}


vnext_go_to_known_good_tag() {
  local repo="$1"
  local tags
  tags="$(cd "$repo" && git tag --list 'gutt/known-good-*' --sort=-creatordate 2>/dev/null || true)"

  if [[ -z "$tags" ]]; then
    msgbox "Known-good recovery" "No known-good tags found.

Expected pattern: gutt/known-good-*"
    return 0
  fi

  local menu_args=()
  local tag commit date subj
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    commit="$(cd "$repo" && git rev-parse "$tag" 2>/dev/null || true)"
    date="$(cd "$repo" && git show -s --format='%cs' "$tag" 2>/dev/null | cut -d' ' -f1 || true)"
    subj="$(cd "$repo" && git show -s --format='%s' "$tag" 2>/dev/null || true)"
    menu_args+=( "$tag" "${commit:0:8} $date $subj" )
  done <<<"$tags"

  local picked
  picked="$(menu "Pick known-good tag" "Select a known-good tag to check out (detached HEAD).

This does not delete anything. You can always return to your previous branch." "${menu_args[@]}")" || return 0

  local prev_branch
  prev_branch="$(cd "$repo" && git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [[ -z "$prev_branch" ]] && prev_branch="(detached)"

  local dirty
  dirty="$(cd "$repo" && git status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    if whiptail --title "$APP_NAME $VERSION" --yesno --defaultno \
      "Working tree has uncommitted changes.

Stash them (stash push) and continue to the known-good tag checkout?" 12 78 3>&1 1>&2 2>&3; then
      run_git_capture "$repo" git stash push -u -m "gutt: auto-stash before known-good checkout"
    else
      msgbox "Aborted" "No changes made."
      return 0
    fi
  fi

  run_git_capture "$repo" git checkout --detach "$picked"

  msgbox "Now at known-good tag" "Checked out:
$picked

Previous branch:
$prev_branch

You are now in a detached HEAD state.

To get back later:
- git checkout $prev_branch
- or: git checkout -"

  if whiptail --title "$APP_NAME $VERSION" --yesno --defaultno \
    "Optional (recommended):

Create a new branch from this known-good state and switch to it?" 12 78 3>&1 1>&2 2>&3; then
    local new_branch rc
    set +e
    new_branch="$(inputbox "Enter new branch name" "recovery/${picked//\//-}")"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && return 0
    [[ -z "$new_branch" ]] && return 0
    run_git_capture "$repo" git checkout -b "$new_branch"
    msgbox "Recovery branch created" "Now on branch:
$new_branch"
  fi
}


vnext_recover_by_branching() {
  local repo="$1"
  local tags
  tags="$(cd "$repo" && git tag --list 'gutt/known-good-*' --sort=-creatordate 2>/dev/null || true)"

  if [[ -z "$tags" ]]; then
    msgbox "Recover by branching" "No known-good tags found.

Expected pattern: gutt/known-good-*"
    return 0
  fi

  local menu_args=()
  local tag commit date subj
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    commit="$(cd "$repo" && git rev-parse "$tag" 2>/dev/null || true)"
    date="$(cd "$repo" && git show -s --format='%cs' "$tag" 2>/dev/null | cut -d' ' -f1 || true)"
    subj="$(cd "$repo" && git show -s --format='%s' "$tag" 2>/dev/null || true)"
    menu_args+=( "$tag" "${commit:0:8} $date $subj" )
  done <<<"$tags"

  local picked
  picked="$(menu "Pick known-good tag" "Select a known-good tag to branch from.

This creates a NEW branch and switches to it." "${menu_args[@]}")" || return 0

  local dirty
  dirty="$(cd "$repo" && git status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    if whiptail --title "$APP_NAME $VERSION" --yesno --defaultno \
      "Working tree has uncommitted changes.

Stash them (stash push) and continue to create a recovery branch?" 12 78 3>&1 1>&2 2>&3; then
      run_git_capture "$repo" git stash push -u -m "gutt: auto-stash before recovery branch"
    else
      msgbox "Aborted" "No changes made."
      return 0
    fi
  fi

  local new_branch rc
  set +e
  new_branch="$(inputbox "Enter new branch name" "recovery/${picked//\//-}")"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] && return 0
  [[ -z "$new_branch" ]] && return 0

  if ! whiptail --title "$APP_NAME $VERSION" --yesno --defaultno \
    "Create and switch to this branch?

Branch: $new_branch
From tag: $picked" 12 78 3>&1 1>&2 2>&3; then
    msgbox "Aborted" "No changes made."
    return 0
  fi

  run_git_capture "$repo" git checkout -b "$new_branch" "$picked"
  msgbox "Recovery branch ready" "Now on branch:
$new_branch

Based on:
$picked"
}

