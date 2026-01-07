#!/usr/bin/env bash
# GUTT - Git User TUI Tool (v0.3.5)

set -Eeuo pipefail

VERSION="v0.3.5"
APP_NAME="GUTT"
CFG_DIR="${HOME}/.config/gutt"
CACHE_DIR="${HOME}/.cache/gutt"
CFG_FILE="${CFG_DIR}/config"
REPOS_FILE="${CFG_DIR}/repos.list"
LAST_REPO_FILE="${CACHE_DIR}/last_repo"

# -------------------------
# Utilities
# -------------------------
die() { printf '%s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

# Tempfile tracking (prevents orphaned /tmp files on exit/crash)
__GUTT_TMPFILES=()
mktemp_gutt() {
  local t
  t="$(mktemp "${TMPDIR:-/tmp}/gutt.XXXXXX")"
  __GUTT_TMPFILES+=("$t")
  printf '%s' "$t"
}
gutt_cleanup_tmpfiles() {
  local f
  for f in "${__GUTT_TMPFILES[@]:-}"; do
    rm -f "$f" 2>/dev/null || true
  done
}
trap 'gutt_cleanup_tmpfiles' EXIT


# Read key=value from config (bash-safe)
cfg_get() {
  local key="$1" default="${2:-}"
  [[ -f "$CFG_FILE" ]] || { printf '%s' "$default"; return; }
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$CFG_FILE" 2>/dev/null | tail -n1 || true)"
  [[ -n "$line" ]] || { printf '%s' "$default"; return; }
  printf '%s' "${line#*=}"
}

cfg_set() {
  local key="$1" val="$2"
  mkdir -p "$CFG_DIR"
  touch "$CFG_FILE"

  # Escape for safe sed use (replacement + key regex)
  local key_re esc_val
  key_re="$(printf '%s' "$key" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')"
  esc_val="$(printf '%s' "$val" | sed -e 's/[&|]/\\&/g')"

  if grep -qE "^[[:space:]]*${key_re}=" "$CFG_FILE"; then
    local tmp
    tmp="$(mktemp_gutt)"
    sed -e "s|^[[:space:]]*${key_re}=.*$|${key}=${esc_val}|" "$CFG_FILE" >"$tmp"
    mv -f "$tmp" "$CFG_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CFG_FILE"
  fi
}

ensure_files() {
  mkdir -p "$CFG_DIR" "$CACHE_DIR"
  [[ -f "$CFG_FILE" ]] || {
    cat >"$CFG_FILE" <<'EOF'
# GUTT config (key=value)
remember_recent=1
recent_limit=10

# pull modes: ff-only | merge | rebase
default_pull_mode=ff-only

# 1 = fetch --all --prune before push
auto_fetch_before_push=1

# 1 = offer local backup tag before destructive ops
offer_backup_tag_before_danger=1

# force push mode: force-with-lease
force_push_mode=force-with-lease

# required phrase before force push / rewrite
confirm_phrase_forcepush=OVERWRITE REMOTE
EOF
  }
  [[ -f "$REPOS_FILE" ]] || : >"$REPOS_FILE"
}

# -------------------------
# UI helpers
# -------------------------
msgbox() {
  # Display-only helper: never allow whiptail return codes to trip errexit.
  local had_e=0
  [[ $- == *e* ]] && had_e=1
  set +e
  whiptail --title "$APP_NAME $VERSION" --msgbox "$1" 18 80 </dev/tty >/dev/tty 2>/dev/tty
  ((had_e)) && set -e
  return 0
}

inputbox() {
  local prompt="$1" default="${2:-}"
  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  whiptail --title "$APP_NAME $VERSION" --inputbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3
  rc=$?
  ((had_e)) && set -e
  return $rc
}

menu() {
  local title="$1" text="$2"
  shift 2
  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  whiptail --title "$title" --menu "$text" 20 90 12 "$@" 3>&1 1>&2 2>&3
  rc=$?
  ((had_e)) && set -e
  return $rc
}
# Run an action without letting non-zero returns trip errexit (set -e).
# Captures the action exit status in GUTT_LAST_RC.
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


yesno() {
  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "$1" 12 78 3>&1 1>&2 2>&3
  rc=$?
  ((had_e)) && set -e
  return $rc
}

textbox() {
  # Usage:
  #   textbox "/path/to/file"
  #   textbox "Title here" "/path/to/file"
  #
  # Display-only helper: never allow whiptail return codes to trip errexit.
  local title file had_e=0
  [[ $- == *e* ]] && had_e=1

  if [[ $# -eq 1 ]]; then
    title="$APP_NAME $VERSION"
    file="$1"
  elif [[ $# -ge 2 ]]; then
    title="$1"
    file="$2"
  else
    msgbox "Internal error: textbox() called with no arguments."
    return 0
  fi

  if [[ ! -r "$file" ]]; then
    msgbox "Unable to open file for viewing:\n\n$file"
    return 0
  fi

  set +e
  whiptail --title "$title" --textbox "$file" 22 90 </dev/tty >/dev/tty 2>/dev/tty
  ((had_e)) && set -e
  return 0
}

# -------------------------
# Git helpers (safe wrappers)
# -------------------------
run_git_capture() {
  # Usage: run_git_capture <repo> <command...>
  local repo="$1"; shift
  local tmp
  tmp="$(mktemp_gutt)"
  (cd "$repo" && "$@") >"$tmp" 2>&1 || true
  textbox "$tmp"
  rm -f "$tmp"
}

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

validate_branch_name() {
  # Usage: validate_branch_name <repo> <name>
  local repo="$1" name="$2"

  [[ -n "$name" ]] || return 1
  [[ "$name" != "main" && "$name" != "master" ]] || return 1
  [[ "$name" != "HEAD" ]] || return 1

  (cd "$repo" && git check-ref-format --branch "$name" >/dev/null 2>&1)
}

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

# -------------------------
# vNext: Tags & Known-Good
# -------------------------

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



confirm_phrase() {
  # Usage: confirm_phrase "Prompt..." "PHRASE"
  local prompt="$1" phrase="$2"
  local got
  got="$(whiptail --title "$APP_NAME $VERSION" --inputbox "$prompt\n\nType exactly:\n$phrase" 12 78 "" 3>&1 1>&2 2>&3)" || return 1
  [[ "$got" == "$phrase" ]]
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

# -------------------------
# Safety and deps
# -------------------------
preflight() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    local su_hint=""
    if [[ -n "${SUDO_USER:-}" ]]; then
      su_hint="\n\nHint: this looks like sudo was used (SUDO_USER=${SUDO_USER})."
    fi

    msgbox "Detected EUID=0: you are running as root (usually because you used sudo).${su_hint}

Do NOT run GUTT with sudo. It can:
 - create root-owned files in your repo
 - break your normal Git workflow
 - cause permission issues later

Run it as your normal user instead:
  ./gutt.sh

If you installed GUTT into PATH, just run:
  gutt

(Install-to-PATH is per-user, so install without sudo.)

Exiting." || true
    exit 1
  fi

  need_cmd git
  need_cmd whiptail
  ensure_files
}

# -------------------------
# Repo remembering
# -------------------------
repos_bump_recent() {
  local path="$1"
  local limit
  limit="$(cfg_get recent_limit 10)"
  [[ -n "$path" ]] || return 0

  awk -v p="$path" '{if($0!=p) print $0}' "$REPOS_FILE" > "${REPOS_FILE}.tmp" 2>/dev/null || true
  mv "${REPOS_FILE}.tmp" "$REPOS_FILE" 2>/dev/null || true

  { printf '%s\n' "$path"; cat "$REPOS_FILE"; } > "${REPOS_FILE}.tmp"
  mv "${REPOS_FILE}.tmp" "$REPOS_FILE"

  head -n "$limit" "$REPOS_FILE" > "${REPOS_FILE}.tmp" 2>/dev/null || true
  mv "${REPOS_FILE}.tmp" "$REPOS_FILE" 2>/dev/null || true

  printf '%s' "$path" > "$LAST_REPO_FILE"
  cfg_set default_repo "$path"
}

new_project_wizard() {
  local base name path remote
  base="$(inputbox "Base directory for new project" "$HOME/git")" || return 1
  name="$(inputbox "New project folder name" "")" || return 1
  [[ -n "$name" ]] || return 1
  path="${base%/}/$name"

  if [[ -e "$path" ]]; then
    msgbox "Path already exists:\n\n$path"
    return 1
  fi

  mkdir -p "$path" || { msgbox "Failed to create:\n\n$path"; return 1; }

  if yesno "Initialise as a Git repo now?" ; then
    (cd "$path" && git init) || { msgbox "git init failed."; return 1; }
  fi

  if yesno "Add a remote (origin) now?" ; then
    remote="$(inputbox "Remote URL (e.g. https://github.com/user/repo.git)" "")" || true
    if [[ -n "${remote:-}" ]]; then
      (cd "$path" && git remote add origin "$remote") || msgbox "Failed to add remote."
    fi
  fi

  msgbox "Created:\n\n$path"
  printf '%s' "$path"
}

select_repo() {
  local choice repo_path
  while true; do
    local last
    last="$(cfg_get default_repo "")"
    local items=()

    if [[ -n "$last" && -d "$last" ]]; then
      items+=("LAST" "Use last: $last")
    fi

    if [[ -s "$REPOS_FILE" ]]; then
      local i=0
      while IFS= read -r line; do
        [[ -n "$line" && -d "$line" ]] || continue
        i=$((i+1))
        items+=("R$i" "Recent: $line")
      done < "$REPOS_FILE"
    fi

    items+=("BROWSE" "Browse to a directory")
    items+=("NEW" "New project wizard (create folder)")
    items+=("BACK" "Back")

    choice="$(menu "$APP_NAME $VERSION" "Select a repository directory" "${items[@]}")" || return 1

    case "$choice" in
      LAST) repo_path="$last" ;;
      R*)   repo_path="$(sed -n "${choice#R}p" "$REPOS_FILE" 2>/dev/null || true)" ;;
      BROWSE) repo_path="$(inputbox "Enter a directory path" "$PWD")" || continue ;;
      NEW) repo_path="$(new_project_wizard)" || continue ;;
      BACK) return 1 ;;
      *) continue ;;
    esac

    [[ -n "$repo_path" ]] || continue
    [[ -d "$repo_path" ]] || { msgbox "Directory does not exist:\n\n$repo_path"; continue; }

    local root
    root="$(git_repo_root "$repo_path")"
    if [[ -n "$root" ]]; then
      repo_path="$root"
    else
      if yesno "Not a Git repo:\n\n$repo_path\n\nInitialise with 'git init'?" ; then
        (cd "$repo_path" && git init) || { msgbox "git init failed."; continue; }
      else
        continue
      fi
    fi

    repos_bump_recent "$repo_path"
    printf '%s' "$repo_path"
    return 0
  done
}

# -------------------------
# Dashboard and simple actions
# -------------------------
show_dashboard() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  repo_summary "$repo" > "$tmp"
  textbox "$tmp"
  rm -f "$tmp"
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



vnext_push_menu() {
  local repo="$1"
  local branch upstream

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

  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Push\n\nRepo:\n$repo\n\nBranch: $branch\nUpstream: ${upstream:-"(none)"}" \
      "CUR"  "Push current branch" \
      "ALL"  "Push all branches (advanced)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      CUR) vnext_push_current_branch "$repo" ;;
      ALL) vnext_push_all_branches "$repo" ;;
      BACK) return 0 ;;
    esac

    # refresh upstream display after actions
    upstream="$(git_upstream "$repo")"
  done
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

# -------------------------
# Stage / Commit
# -------------------------
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

action_stage_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Staging (repo: $repo)" \
      "SALL" "Stage all changes" \
      "SSEL" "Stage by file (choose)" \
      "UALL" "Unstage all" \
      "USEL" "Unstage by file (choose)" \
      "DISC" "Discard changes to file (danger)" \
      "BACK" "Back")" || return 0
    case "$choice" in
      SALL) run_git_capture "$repo" git add -A ;;
      SSEL) action_stage_by_file "$repo" ;;
      UALL) run_git_capture "$repo" git reset ;;
      USEL) action_unstage_by_file "$repo" ;;
      DISC) action_discard_file "$repo" ;;
      BACK) return 0 ;;
    esac
  done
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


action_commit_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Commit (repo: $repo)" \
      "PRE" "Preview staged / unstaged (no commit)" \
      "COM" "Commit (requires staged changes)" \
      "ALL" "Commit all (stage everything) (guarded)" \
      "WIP" "Checkpoint (WIP) commit" \
      "AMD" "Amend last commit" \
      "MSG" "Edit last commit message only" \
      "UND" "Undo last commit (soft reset) (guarded)" \
      "BACK" "Back")" || return 0
    case "$choice" in
      PRE) action_commit_preview "$repo" ;;
      COM) action_commit "$repo" ;;
      ALL) action_commit_all "$repo" ;;
      WIP) action_checkpoint_commit "$repo" ;;
      AMD) action_amend "$repo" ;;
      MSG) action_reword_last "$repo" ;;
      UND) action_undo_last_soft "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Stash
# -------------------------
stash_pick() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git stash list) >"$tmp" 2>/dev/null || true
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    msgbox "No stashes."
    return 1
  fi
  local items=()
  local i=0
  while IFS= read -r line; do
    i=$((i+1))
    local key="stash@{${i-1}}"
    items+=("$key" "$line")
  done <"$tmp"
  rm -f "$tmp"
  whiptail --title "$APP_NAME $VERSION" --menu "Select a stash" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3 || return 1
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

action_stash_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Stash (repo: $repo)" \
      "SAVE" "Stash push (with message)" \
      "LIST" "List stashes" \
      "APPL" "Apply stash" \
      "POP" "Pop stash" \
      "DROP" "Drop stash" \
      "BRCH" "Stash branch (create branch from stash)" \
      "BACK" "Back")" || return 0
    case "$choice" in
      SAVE) action_stash_push "$repo" ;;
      LIST) run_git_capture "$repo" git stash list ;;
      APPL) action_stash_apply "$repo" ;;
      POP)  action_stash_pop "$repo" ;;
      DROP) action_stash_drop "$repo" ;;
      BRCH) action_stash_branch "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Branches
# -------------------------
pick_branch() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git branch --format='%(refname:short)') >"$tmp" 2>/dev/null || true
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  local items=()
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    items+=("$b" "")
  done <"$tmp"
  rm -f "$tmp"
  whiptail --title "$APP_NAME $VERSION" --menu "Select a branch" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3 || return 1
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

action_branch_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Branches (repo: $repo)" \
      "LIST" "List branches" \
      "NEW" "Create branch" \
      "SWI" "Switch branch" \
      "REN" "Rename current branch" \
      "UPT" "Upstream tracking (view/set)" \
      "DEL" "Delete branch (local)" \
      "BACK" "Back")" || return 0
    case "$choice" in
      LIST) run_git_capture "$repo" git branch -vv ;;
      NEW)  action_branch_create "$repo" ;;
      SWI)  action_branch_switch "$repo" ;;
      REN)  action_branch_rename "$repo" ;;
      DEL)  action_branch_delete "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Merge / Rebase
# -------------------------
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

action_merge_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Merge / Rebase (repo: $repo)" \
      "MRG" "Merge branch into current" \
      "ABM" "Abort merge" \
      "RBS" "Pull rebase (git pull --rebase)" \
      "IRB" "Interactive rebase (DANGER)" \
      "ARB" "Abort rebase" \
      "BACK" "Back")" || return 0
    case "$choice" in
      MRG) action_merge_branch "$repo" ;;
      ABM) run_git_capture "$repo" git merge --abort ;;
      RBS) run_git_capture "$repo" git pull --rebase ;;
      IRB) action_interactive_rebase "$repo" ;;
      ARB) run_git_capture "$repo" git rebase --abort ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Remotes / Upstream
# -------------------------
pick_remote() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  (cd "$repo" && git remote) >"$tmp" 2>/dev/null || true
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  local items=()
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    items+=("$r" "")
  done <"$tmp"
  rm -f "$tmp"
  whiptail --title "$APP_NAME $VERSION" --menu "Select a remote" 18 70 10 "${items[@]}" 3>&1 1>&2 2>&3 || return 1
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

action_remote_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Remotes (repo: $repo)" \
      "LIST" "List remotes" \
      "ADD" "Add remote" \
      "SET" "Set remote URL" \
      "DEL" "Remove remote" \
      "BACK" "Back")" || return 0
    case "$choice" in
      LIST) run_git_capture "$repo" git remote -v ;;
      ADD)  action_remote_add "$repo" ;;
      SET)  action_remote_seturl "$repo" ;;
      DEL)  action_remote_remove "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Logs / Diffs
# -------------------------
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

action_log_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Logs & diffs (repo: $repo)" \
      "LOG" "Log (last 30, oneline)" \
      "GRF" "Log graph (last 50)" \
      "SHW" "Show commit (by hash)" \
      "DIF" "Diff working tree" \
      "DIFC" "Diff staged" \
      "DIFU" "Diff vs upstream" \
      "BACK" "Back")" || return 0
    case "$choice" in
      LOG)  run_git_capture "$repo" git log --oneline --decorate -n 30 ;;
      GRF)  run_git_capture "$repo" git log --graph --oneline --decorate -n 50 ;;
      SHW)  action_show_commit "$repo" ;;
      DIF)  run_git_capture "$repo" git diff ;;
      DIFC) run_git_capture "$repo" git diff --cached ;;
      DIFU) action_diff_upstream "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Hygiene assistant
# -------------------------
gitignore_suggest() {
  local repo="$1"
  local suggestions=()

  [[ -d "$repo/node_modules" ]] && suggestions+=("node_modules/")
  [[ -d "$repo/.venv" ]] && suggestions+=(".venv/")
  [[ -d "$repo/venv" ]] && suggestions+=("venv/")
  [[ -d "$repo/__pycache__" ]] && suggestions+=("__pycache__/")
  [[ -d "$repo/.idea" ]] && suggestions+=(".idea/")
  [[ -d "$repo/.vscode" ]] && suggestions+=(".vscode/")

  if [[ "${#suggestions[@]}" -eq 0 ]]; then
    msgbox "No obvious .gitignore suggestions found in a quick scan."
    return 0
  fi

  local tmp; tmp="$(mktemp_gutt)"
  cat >"$tmp" <<EOF
Suggested .gitignore entries:

$(printf '%s\n' "${suggestions[@]}")

Append to .gitignore?
EOF
  textbox "$tmp"
  rm -f "$tmp"

  if yesno "Append these entries to .gitignore?\n\n(Will avoid duplicates.)" ; then
    touch "$repo/.gitignore"
    for s in "${suggestions[@]}"; do
      grep -qxF "$s" "$repo/.gitignore" 2>/dev/null || printf '%s\n' "$s" >> "$repo/.gitignore"
    done
    msgbox "Updated .gitignore."
  fi
}

hygiene_scan() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  local dirty_count staged_count untracked_count det_head upstream
  dirty_count="$(cd "$repo" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  staged_count="$(cd "$repo" && git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
  untracked_count="$(cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
  det_head="no"; git_is_detached "$repo" && det_head="YES"
  upstream="$(git_upstream "$repo")"
  [[ -n "$upstream" ]] || upstream="(none)"

  cat >"$tmp" <<EOF
Repo hygiene report

Detached HEAD:  $det_head
Upstream set:   $upstream

Changed files:  $dirty_count
Staged files:   $staged_count
Untracked:      $untracked_count

.gitignore:     $( [[ -f "$repo/.gitignore" ]] && echo "present" || echo "missing" )

Notes:
- GUTT refuses destructive ops when the repo is dirty.
- Keep secrets out of repos. Consider a pre-commit hook if needed.
EOF
  textbox "$tmp"
  rm -f "$tmp"
}

action_hygiene_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Hygiene assistant (repo: $repo)" \
      "SCAN" "Show hygiene report" \
      "IGN" "Suggest/append .gitignore entries" \
      "BACK" "Back")" || return 0
    case "$choice" in
      SCAN) hygiene_scan "$repo" ;;
      IGN)  gitignore_suggest "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Danger zone
# -------------------------
action_reset_menu() {
  local repo="$1"
  local choice
  choice="$(menu "$APP_NAME $VERSION" "Reset types (read carefully)" \
    "SOFT" "reset --soft HEAD~1 (keeps changes staged)" \
    "MIX"  "reset --mixed HEAD~1 (keeps changes unstaged)" \
    "HARD" "reset --hard (DANGER: discards changes)" \
    "SPEC" "reset --hard to specific commit (DANGER)" \
    "BACK" "Back")" || return 0

  case "$choice" in
    SOFT)
      danger_preflight "$repo" "git reset --soft HEAD~1" || return 0
      offer_backup_tag "$repo"
      run_git_capture "$repo" git reset --soft HEAD~1
      ;;
    MIX)
      danger_preflight "$repo" "git reset --mixed HEAD~1" || return 0
      offer_backup_tag "$repo"
      run_git_capture "$repo" git reset --mixed HEAD~1
      ;;
    HARD)
      danger_preflight "$repo" "git reset --hard HEAD" || return 0
      offer_backup_tag "$repo"
      run_git_capture "$repo" git reset --hard
      ;;
    SPEC)
      local h
      h="$(inputbox "Commit to reset to (hash or ref)" "")" || return 0
      [[ -n "$h" ]] || return 0
      danger_preflight "$repo" "git reset --hard $h" || return 0
      offer_backup_tag "$repo"
      run_git_capture "$repo" git reset --hard "$h"
      ;;
    BACK) return 0 ;;
  esac
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

action_danger_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "DANGER ZONE (repo: $repo)" \
      "RFL" "View reflog (rescue)" \
      "RST" "Reset (soft/mixed/hard)" \
      "CLN" "Clean untracked files (dry-run first)" \
      "FRC" "Force push (with lease) (DANGER)" \
      "NOP" "Rewrite history baseline ('no paper trail')" \
      "BACK" "Back")" || return 0
    case "$choice" in
      RFL) gutt_run_action run_git_capture "$repo" git reflog -n 30 ;;
      RST) gutt_run_action action_reset_menu "$repo" ;;
      CLN) gutt_run_action action_clean_untracked "$repo" ;;
      FRC) gutt_run_action action_force_push "$repo" ;;
      NOP) gutt_run_action action_no_paper_trail "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Settings
# -------------------------

# -------------------------
# PATH shortcut helper (SAFE / ADDITIVE) - DaST-style
#
# Goals:
# - Install a 'gutt' shortcut without breaking script self-discovery.
# - Never overwrite "foreign" gutt commands in unexpected locations.
# - Default NO on confirmations.
# - Cancel/Esc safe under set -Eeuo pipefail (wrappers already guarded).
# - Removable from safe locations only.
# -------------------------

gutt_self_realpath() {
  readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s
' "${BASH_SOURCE[0]}"
}

gutt_shortcut_status() {
  # Outputs: found(0/1) path realpath is_ours(0/1)
  # "found" means either:
  #   - a gutt command resolves in this shell (command -v), OR
  #   - a managed wrapper exists in common install locations (even if not on PATH in this shell)
  local p="" rp="" ours="0"

  local cv="" tt=""
  cv="$(command -v gutt 2>/dev/null || true)"
  tt="$(type -t gutt 2>/dev/null || true)"

  if [[ -n "$cv" ]]; then
    # If gutt is an alias/function/builtin, we still report "found",
    # but we can't safely treat it as a wrapper file.
    if [[ "$tt" != "file" && "$tt" != "keyword" ]]; then
      printf '1 %s "" 0
' "$cv"
      return 0
    fi
    p="$cv"
  fi

  # If not found on PATH (or not a file), look for common wrapper locations directly.
  if [[ -z "$p" || ! -x "$p" ]]; then
    local cand
    for cand in "$HOME/.local/bin/gutt" "$HOME/bin/gutt" "/usr/local/bin/gutt"; do
      if [[ -x "$cand" ]]; then
        p="$cand"
        break
      fi
    done
  fi

  if [[ -n "$p" && -f "$p" ]]; then
    rp="$(readlink -f "$p" 2>/dev/null || true)"

    # If /usr/local/bin/gutt (or ~/.local/bin/gutt) is a wrapper (not symlink), extract target.
    if [[ -f "$p" && ! -L "$p" ]]; then
      # Marker makes "ours" detection robust even if entry target has moved.
      if grep -qE '^[[:space:]]*# GUTT_WRAPPER[[:space:]]*$' "$p" 2>/dev/null; then
        ours="1"
      fi

      # Legacy wrapper support (pre-marker installs)
      # If the wrapper lives in a safe user location and contains GUTT_ENTRY (or references gutt.sh),
      # treat it as ours so we can update it cleanly.
      if [[ "$ours" != "1" ]]; then
        case "$p" in
          "$HOME/.local/bin/gutt" | "$HOME/bin/gutt")
            if grep -qE '^[[:space:]]*GUTT_ENTRY=' "$p" 2>/dev/null; then
              ours="1"
            elif grep -qF "gutt.sh" "$p" 2>/dev/null; then
              ours="1"
            fi
            ;;
        esac
      fi

      local _t=""
      _t="$(grep -E '^[[:space:]]*GUTT_ENTRY=' "$p" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*GUTT_ENTRY=//')"
      _t="${_t%\"}"; _t="${_t#\"}"
      _t="${_t%\'}"; _t="${_t#\'}"
      if [[ -n "$_t" ]]; then
        rp="$(readlink -f -- "$_t" 2>/dev/null || printf '%s' "$_t")"
      fi
    fi
  fi

  local self=""
  self="$(gutt_self_realpath 2>/dev/null || true)"
  if [[ "$ours" != "1" && -n "$rp" && -n "$self" && "$rp" == "$self" ]]; then
    ours="1"
  fi

  if [[ -n "$p" ]]; then
    printf '1 %s %s %s
' "$p" "$rp" "$ours"
  else
    printf '0 "" "" 0
'
  fi
}

# PATH integration richer state (no UI wiring yet)
# States:
# - INSTALLED   : gutt resolves on PATH and is managed by GUTT
# - PARTIAL     : wrapper exists but its directory is not on PATH
# - FOREIGN     : gutt resolves on PATH but is not managed by GUTT
# - UNINSTALLED : no wrapper and no gutt on PATH
gutt_path_integration_state() {
  # PATH-authoritative semantic state for the *current shell*.
  #
  # States:
  # - INSTALLED   : gutt resolves on PATH and is managed by this GUTT
  # - FOREIGN     : gutt resolves on PATH but is not managed by this GUTT
  # - PARTIAL     : a wrapper exists in a common install location, but PATH cannot resolve gutt
  # - UNINSTALLED : no wrapper and no gutt on PATH
  local cv="" tt="" p="" ours="0"

  cv="$(command -v gutt 2>/dev/null || true)"
  tt="$(type -t gutt 2>/dev/null || true)"

  if [[ -n "$cv" ]]; then
    # If gutt is an alias/function/builtin, it's callable but not a wrapper we can own/manage.
    if [[ "$tt" != "file" && "$tt" != "keyword" ]]; then
      echo "FOREIGN"
      return 0
    fi

    p="$cv"

    # Determine whether this PATH-resolved gutt is ours.
    if [[ -n "$p" && -f "$p" ]]; then
      # Marker makes "ours" detection robust even if entry target has moved.
      if grep -qE '^[[:space:]]*# GUTT_WRAPPER[[:space:]]*$' "$p" 2>/dev/null; then
        ours="1"
      else
        # Legacy wrapper support (pre-marker installs)
        case "$p" in
          "$HOME/.local/bin/gutt" | "$HOME/bin/gutt")
            if grep -qE '^[[:space:]]*GUTT_ENTRY=' "$p" 2>/dev/null; then
              ours="1"
            elif grep -qF "gutt.sh" "$p" 2>/dev/null; then
              ours="1"
            fi
            ;;
        esac
      fi

      # If wrapper exposes a target, also compare it to our current entry path.
      if [[ "$ours" != "1" ]]; then
        local _t="" rp="" self=""
        _t="$(grep -E '^[[:space:]]*GUTT_ENTRY=' "$p" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*GUTT_ENTRY=//')"
        _t="${_t%\"}"; _t="${_t#\"}"
        _t="${_t%\'}"; _t="${_t#\'}"
        if [[ -n "$_t" ]]; then
          rp="$(readlink -f -- "$_t" 2>/dev/null || printf '%s' "$_t")"
          self="$(gutt_self_realpath 2>/dev/null || true)"
          if [[ -n "$rp" && -n "$self" && "$rp" == "$self" ]]; then
            ours="1"
          fi
        fi
      fi
    fi

    if [[ "$ours" == "1" ]]; then
      echo "INSTALLED"
    else
      echo "FOREIGN"
    fi
    return 0
  fi

  # Not callable via PATH in this shell. Look for a disk-only wrapper (partial install).
  if [[ -x "$HOME/.local/bin/gutt" || -x "$HOME/bin/gutt" ]]; then
    echo "PARTIAL"
  else
    echo "UNINSTALLED"
  fi
}


gutt_path_integration_label() {
  local st="${1:-}"
  if [[ -z "$st" ]]; then
    st="$(gutt_path_integration_state)"
  fi
  case "$st" in
    INSTALLED) gutt_run_action echo "PATH Integration: INSTALLED (this GUTT)" ;;
    PARTIAL) gutt_run_action echo "PATH Integration: PARTIAL (wrapper present, not on PATH)" ;;
    FOREIGN) gutt_run_action echo "PATH Integration: FOREIGN (another gutt on PATH)" ;;
    UNINSTALLED) gutt_run_action echo "PATH Integration: UNINSTALLED" ;;
    *)           echo "PATH Integration: UNINSTALLED" ;;
  esac
}



gutt_detect_user_shell() {
  # Best-effort shell detection for selecting a user rc file.
  # Prefer $SHELL, fall back to parent process.
  local sh=""
  sh="${SHELL##*/}"
  sh="${sh,,}"

  if [[ -z "$sh" ]]; then
    sh="$(ps -p "${PPID:-0}" -o comm= 2>/dev/null | head -n 1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
  fi

  case "$sh" in
    zsh|bash) echo "$sh" ;;
    *) echo "bash" ;;
  esac
}

gutt_path_rc_file_for_shell() {
  # Echo the preferred rc file for the detected shell.
  local sh
  sh="$(gutt_detect_user_shell)"
  case "$sh" in
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    bash|*)
      if [[ -f "$HOME/.bashrc" ]]; then
        printf '%s\n' "$HOME/.bashrc"
      else
        printf '%s\n' "$HOME/.profile"
      fi
      ;;
  esac
}

gutt_path_managed_block_present() {
  local rcfile="$1"
  [[ -n "$rcfile" ]] || return 1
  grep -Fq "# >>> GUTT PATH >>>" "$rcfile" 2>/dev/null && return 0
  grep -Fq "# <<< GUTT PATH <<<" "$rcfile" 2>/dev/null && return 0
  return 1
}


gutt_path_managed_block_health() {
  # Echo: OK | NONE | MULTIPLE | MALFORMED
  local rcfile="$1"
  [[ -n "$rcfile" ]] || { echo "NONE"; return 0; }

  local start_count end_count
  start_count="$(grep -Fxc "# >>> GUTT PATH >>>" "$rcfile" 2>/dev/null || echo 0)"
  end_count="$(grep -Fxc "# <<< GUTT PATH <<<" "$rcfile" 2>/dev/null || echo 0)"

  if [[ "${start_count:-0}" -eq 0 && "${end_count:-0}" -eq 0 ]]; then
    echo "NONE"
    return 0
  fi

  if [[ "${start_count:-0}" -eq 1 && "${end_count:-0}" -eq 1 ]]; then
    local sline eline
    sline="$(grep -Fn "# >>> GUTT PATH >>>" "$rcfile" 2>/dev/null | head -n 1 | cut -d: -f1)"
    eline="$(grep -Fn "# <<< GUTT PATH <<<" "$rcfile" 2>/dev/null | head -n 1 | cut -d: -f1)"
    if [[ -n "$sline" && -n "$eline" && "$sline" -lt "$eline" ]]; then
      echo "OK"
    else
      echo "MALFORMED"
    fi
    return 0
  fi

  echo "MULTIPLE"
  return 0
}

gutt_path_scan_unmanaged_lines() {
  # Prints up to 40 matching lines outside the managed block:
  # lines that reference .local/bin and PATH
  local rcfile="$1"
  [[ -n "$rcfile" ]] || return 0
  awk '
    BEGIN { in=0 }
    /# >>> GUTT PATH >>>/ { in=1; next }
    /# <<< GUTT PATH <<</ { in=0; next }
    {
      if (!in && $0 ~ /\.local\/bin/ && $0 ~ /PATH/) {
        printf "%d:%s
", NR, $0
      }
    }
  ' "$rcfile" 2>/dev/null | head -n 40
}

gutt_path_show_scan_report() {
  local sh rcfile health unmanaged
  sh="$(gutt_detect_user_shell)"
  rcfile="$(gutt_path_rc_file_for_shell)"
  health="$(gutt_path_managed_block_health "$rcfile")"
  unmanaged="$(gutt_path_scan_unmanaged_lines "$rcfile")"

  local msg=""
  msg+="Shell: $sh
"
  msg+="Config file: $rcfile

"

  case "$health" in
    NONE)      msg+="Managed block: not present
" ;;
    OK)        msg+="Managed block: present (OK)
" ;;
    MULTIPLE)  msg+="Managed block: ⚠ multiple marker blocks detected
" ;;
    MALFORMED) msg+="Managed block: ⚠ malformed markers/order detected
" ;;
    *)         msg+="Managed block: unknown
" ;;
  esac

  if [[ -n "$unmanaged" ]]; then
    msg+="
⚠ Legacy/unmanaged PATH edits referencing .local/bin found (outside managed block):
"
    msg+="$unmanaged
"
    msg+="
Note: GUTT will not remove unknown PATH lines automatically.
"
  else
    msg+="
No legacy/unmanaged .local/bin PATH edits detected outside the managed block.
"
  fi

  msgbox "$msg"
  return 0
}

gutt_path_repair_managed_block() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    msgbox "Per-user install. Run GUTT as your normal user."
    return 0
  fi

  # Repairs only the content between the first pair of our markers (if valid).
  local sh rcfile health rc
  sh="$(gutt_detect_user_shell)"
  rcfile="$(gutt_path_rc_file_for_shell)"
  health="$(gutt_path_managed_block_health "$rcfile")"

  if [[ "$health" == "NONE" ]]; then
    msgbox "No managed block to repair.

File:
$rcfile"
    return 0
  fi

  if [[ "$health" != "OK" ]]; then
    msgbox "⚠ Managed block markers are not in a simple repairable state (health=$health).

File:
$rcfile

GUTT will not attempt an automatic repair here. Use the scan report and fix manually if needed."
    return 0
  fi

  if ! yesno "🛠 Repair managed PATH block

Shell: $sh
File: $rcfile

This will ONLY replace the content between:
  # >>> GUTT PATH >>>
  # <<< GUTT PATH <<<

with the canonical line:
  export PATH=\"\$HOME/.local/bin:\$PATH\"

Proceed?"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp_gutt)"

  set +e
  awk '
    BEGIN { in=0; done=0 }
    /^# >>> GUTT PATH >>>[[:space:]]*$/ {
      print
      if (!done) {
        print "export PATH=\"$HOME/.local/bin:$PATH\""
        in=1
      }
      next
    }
    /^# <<< GUTT PATH <<<[[:space:]]*$/ {
      if (in && !done) {
        in=0
        done=1
        print
        next
      }
      print
      next
    }
    {
      if (in && !done) next
      print
    }
  ' "$rcfile" >"$tmp" 2>/dev/null
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to build repaired file (rc=$rc).

File:
$rcfile"
    return 0
  fi

  set +e
  mv -f -- "$tmp" "$rcfile" 2>/dev/null
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to write repaired file (rc=$rc).

File:
$rcfile"
    return 0
  fi

  msgbox "✅ Repaired managed PATH block.

File:
$rcfile

Open a new terminal (or source the file) and try:
  command -v gutt
  gutt"
  return 0
}


gutt_path_purge_and_rebuild_managed_block() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    msgbox "Per-user install. Run GUTT as your normal user."
    return 0
  fi

  local sh rcfile health rc
  sh="$(gutt_detect_user_shell)"
  rcfile="$(gutt_path_rc_file_for_shell)"
  health="$(gutt_path_managed_block_health "$rcfile")"

  if [[ "$health" == "NONE" ]]; then
    msgbox "No managed PATH block markers were found.

File:
$rcfile

Nothing to purge."
    return 0
  fi

  if ! yesno "⚠ Recovery: purge and rebuild managed PATH block

Shell: $sh
File: $rcfile
Health: $health

This will:
- Make a timestamped backup of the file
- Remove ALL GUTT managed-block marker pairs (and their contents) if present
- Remove orphan marker lines if present
- Append a fresh clean managed block at the end

Canonical line:
  export PATH=\"\$HOME/.local/bin:\$PATH\"

Proceed?"; then
    return 0
  fi

  # Ensure file exists
  set +e
  mkdir -p -- "$(dirname -- "$rcfile")" 2>/dev/null
  touch -- "$rcfile" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    msgbox "❌ Failed to prepare config file (rc=$rc).

File:
$rcfile"
    return 0
  fi

  local ts backup tmp
  ts="$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'backup')"
  backup="${rcfile}.gutt.bak.${ts}"
  tmp="$(mktemp_gutt)"

  set +e
  cp -p -- "$rcfile" "$backup" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to create backup (rc=$rc).

File:
$rcfile"
    return 0
  fi

  # Purge logic:
  # - If we see a start marker, buffer until we see an end marker.
  #   If we see a matching end marker, we drop the whole buffered block.
  #   If we reach EOF without an end marker, we emit buffered lines except marker lines.
  # - Orphan end markers are dropped.
  set +e
  awk '
    function flush_buf(    i) {
      for (i=1; i<=bn; i++) {
        if (buf[i] != "# >>> GUTT PATH >>>" && buf[i] != "# <<< GUTT PATH <<<") {
          print buf[i]
        }
      }
      bn=0
    }
    BEGIN { in=0; bn=0 }
    $0 == "# >>> GUTT PATH >>>" {
      in=1
      bn=0
      buf[++bn]=$0
      next
    }
    $0 == "# <<< GUTT PATH <<<" {
      if (in==1) {
        # matched end, drop buffered block and this end marker
        in=0
        bn=0
        next
      }
      # orphan end marker, drop it
      next
    }
    {
      if (in==1) {
        buf[++bn]=$0
        next
      }
      # outside managed block, also drop any stray marker lines
      if ($0 == "# >>> GUTT PATH >>>" || $0 == "# <<< GUTT PATH <<<") next
      print
    }
    END {
      if (in==1) {
        # no end marker, keep buffered content but remove markers
        flush_buf()
      }
    }
  ' "$rcfile" >"$tmp" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to build purged file (rc=$rc).

File:
$rcfile

Backup:
$backup"
    return 0
  fi

  set +e
  {
    printf '\n# >>> GUTT PATH >>>\n'
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    printf '# <<< GUTT PATH <<<\n'
  } >>"$tmp" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to append fresh managed block (rc=$rc).

File:
$rcfile

Backup:
$backup"
    return 0
  fi

  set +e
  mv -f -- "$tmp" "$rcfile" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to write updated file (rc=$rc).

File:
$rcfile

Backup:
$backup"
    return 0
  fi

  msgbox "✅ Purged and rebuilt managed PATH block.

File:
$rcfile
Backup:
$backup

Open a new terminal (or source the file) and try:
  command -v gutt
  gutt"
  return 0
}

gutt_path_remove_managed_block() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    msgbox "Per-user install. Run GUTT as your normal user."
    return 0
  fi

  local sh rcfile health rc
  sh="$(gutt_detect_user_shell)"
  rcfile="$(gutt_path_rc_file_for_shell)"
  health="$(gutt_path_managed_block_health "$rcfile")"

  if [[ "$health" == "NONE" ]]; then
    msgbox "No managed PATH block markers were found.

File:
$rcfile

Nothing to remove."
    return 0
  fi

  if ! yesno "🧹 Remove managed PATH block

Shell: $sh
File: $rcfile
Health: $health

This will:
- Make a timestamped backup of the file
- Remove ALL marker pairs:
    # >>> GUTT PATH >>>
    # <<< GUTT PATH <<<
  and anything between them
- Remove orphan marker lines if present

Note:
- GUTT will NOT remove unknown PATH lines outside the managed block.
- Removing the managed block may mean new terminals can no longer find:
    gutt

Proceed?"; then
    return 0
  fi

  # Ensure file exists
  set +e
  mkdir -p -- "$(dirname -- "$rcfile")" 2>/dev/null
  touch -- "$rcfile" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    msgbox "❌ Failed to prepare config file (rc=$rc).

File:
$rcfile"
    return 0
  fi

  local ts backup tmp
  ts="$(date +%Y%m%d_%H%M%S 2>/dev/null || printf 'backup')"
  backup="${rcfile}.gutt.bak.${ts}"
  tmp="$(mktemp_gutt)"

  set +e
  cp -p -- "$rcfile" "$backup" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to create backup (rc=$rc).

File:
$rcfile"
    return 0
  fi

  # Purge logic:
  # - Drop any complete managed blocks
  # - Drop orphan marker lines
  # - If a start marker is seen without an end marker, keep buffered lines but remove markers
  set +e
  awk '
    function flush_buf(    i) {
      for (i=1; i<=bn; i++) {
        if (buf[i] != "# >>> GUTT PATH >>>" && buf[i] != "# <<< GUTT PATH <<<") {
          print buf[i]
        }
      }
      bn=0
    }
    BEGIN { in=0; bn=0 }
    $0 == "# >>> GUTT PATH >>>" {
      in=1
      bn=0
      buf[++bn]=$0
      next
    }
    $0 == "# <<< GUTT PATH <<<" {
      if (in==1) {
        # matched end, drop buffered block and this end marker
        in=0
        bn=0
        next
      }
      # orphan end marker, drop it
      next
    }
    {
      if (in==1) {
        buf[++bn]=$0
        next
      }
      # outside managed block, also drop any stray marker lines
      if ($0 == "# >>> GUTT PATH >>>" || $0 == "# <<< GUTT PATH <<<") next
      print
    }
    END {
      if (in==1) {
        # no end marker, keep buffered content but remove markers
        flush_buf()
      }
    }
  ' "$rcfile" >"$tmp" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to build updated file (rc=$rc).

File:
$rcfile

Backup:
$backup"
    return 0
  fi

  set +e
  mv -f -- "$tmp" "$rcfile" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
    msgbox "❌ Failed to write updated file (rc=$rc).

File:
$rcfile

Backup:
$backup"
    return 0
  fi

  msgbox "✅ Removed managed PATH block.

File:
$rcfile
Backup:
$backup

Open a new terminal (or source the file) if you want to re-check:
  command -v gutt"
  GUTT_REQUIRE_RESTART=1
  return 0
}

gutt_path_add_managed_block() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    msgbox "Per-user install. Run GUTT as your normal user."
    return 0
  fi

  # Adds a managed PATH block to ensure ~/.local/bin is on PATH.
  # Idempotent: does nothing if the block already exists.
  local rcfile sh rc

  sh="$(gutt_detect_user_shell)"
  rcfile="$(gutt_path_rc_file_for_shell)"

  if ! yesno "🧭 Add ~/.local/bin to PATH\n\nShell: $sh\nConfig file: $rcfile\n\nAdd a managed block to ensure 'gutt' can be found in new terminals?"; then
    return 0
  fi

  if gutt_path_managed_block_present "$rcfile"; then
    msgbox "✅ Managed PATH block already present.\n\nFile:\n$rcfile"
    return 0
  fi

  set +e
  mkdir -p -- "$(dirname -- "$rcfile")" 2>/dev/null
  touch -- "$rcfile" 2>/dev/null
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    msgbox "❌ Failed to prepare config file (rc=$rc).\n\nFile:\n$rcfile"
    return 0
  fi

  set +e
  {
    printf '\n# >>> GUTT PATH >>>\n'
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    printf '# <<< GUTT PATH <<<\n'
  } >>"$rcfile" 2>/dev/null
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    msgbox "❌ Failed to write PATH block (rc=$rc).\n\nFile:\n$rcfile"
    return 0
  fi

  msgbox "✅ Added managed PATH block.\n\nFile:\n$rcfile\n\nOpen a new terminal (or source the file) and try:\n  command -v gutt\n  gutt"
  return 0
}


gutt_shortcut_install_wrapper() {
  # Usage: gutt_shortcut_install_wrapper <dest_path> <entry_real>
  local dest="${1:-}"
  local entry_real="${2:-}"
  [[ -n "$dest" && -n "$entry_real" ]] || return 1

  local root
  root="$(dirname -- "$entry_real" 2>/dev/null || true)"

  local tmp
  tmp="$(mktemp_gutt)"
  cat >"$tmp" <<EOF
#!/usr/bin/env bash
# GUTT_WRAPPER
# Generated by GUTT: PATH integration wrapper (do not edit by hand)
GUTT_ENTRY="$entry_real"
export GUTT_APP_DIR="$root"
exec "\$GUTT_ENTRY" "\$@"
EOF

  chmod 0755 "$tmp" 2>/dev/null || true

  printf '%s
' "$tmp"
  return 0
}

gutt_shortcut_install_user() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    msgbox "Per-user install. Run GUTT as your normal user."
    return 0
  fi

  local found p rp ours
  read -r found p rp ours < <(gutt_shortcut_status)

  # If there's already a foreign gutt, don't overwrite it.
  if [[ "$found" == "1" && -n "$p" ]]; then
    case "$p" in
      "$HOME/.local/bin/gutt" | "$HOME/bin/gutt")
        # safe to manage
        ;;
      *)
        msgbox "A 'gutt' command already exists on your PATH, but it's in an unexpected location:

$p

For safety, GUTT will not overwrite this.

Remove/rename the existing command first."
        return 0
        ;;
    esac
  fi

  local entry entry_real dest_dir dest
  entry="$(gutt_self_realpath || true)"
  [[ -n "$entry" ]] || { msgbox "Couldn't resolve the current GUTT script path."; return 0; }
  entry_real="$(readlink -f -- "$entry" 2>/dev/null || printf '%s' "$entry")"

  dest_dir="$HOME/.local/bin"
  dest="$dest_dir/gutt"

  if ! yesno "🔗 GUTT shortcut

Create/update:

$dest

to point to:

$entry_real

Proceed?"; then
    return 0
  fi

  mkdir -p -- "$dest_dir" 2>/dev/null || true

  local tmp
  tmp="$(gutt_shortcut_install_wrapper "$dest" "$entry_real")" || { msgbox "Failed to build wrapper."; return 0; }

  local _rc
  set +e
  install -m 0755 -- "$tmp" "$dest" 2>/dev/null
  _rc=$?
  rm -f -- "$tmp" 2>/dev/null || true
  set -e

  if [[ $_rc -ne 0 ]]; then
    msgbox "❌ Failed to create/update (rc=$_rc).

Path:
$dest"
    return 0
  fi

  hash -r 2>/dev/null || true

  local cv="" st=""
  cv="$(command -v gutt 2>/dev/null || true)"
  st="$(gutt_path_integration_state 2>/dev/null || true)"

  # Phase C: verify immediately and guide if not callable yet.
  if [[ -z "$cv" || "$st" != "INSTALLED" ]]; then
    if [[ "$st" == "PARTIAL" || -z "$cv" ]]; then
      if yesno "✅ Wrapper installed at:

$dest

But it is not callable yet in this shell.

Current state: PARTIAL

Reason: $dest_dir is not on your PATH (or your shell needs a refresh).

Add a managed PATH block now (recommended)?"; then
        gutt_path_add_managed_block
      else
        msgbox "✅ Wrapper installed at:

$dest

Current state: PARTIAL

To finish setup, add this to your shell config and open a new terminal:

  export PATH="\$HOME/.local/bin:\$PATH"

Then run:
  command -v gutt
  gutt"
      fi
      return 0
    fi

    msgbox "⚠ Wrapper installed at:

$dest

But 'gutt' currently resolves to:
$cv

State: ${st:-UNKNOWN}

For safety, GUTT will not change your PATH order. If you want this install to take precedence, adjust PATH so $dest_dir comes before the above location, then open a new terminal."
    return 0
  fi

  msgbox "✅ Installed.

Verified:
  command -v gutt -> $cv

You can now run:

  gutt"
  return 0
}

gutt_shortcut_remove() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    msgbox "Per-user install. Run GUTT as your normal user."
    return 0
  fi

  local found p rp ours
  read -r found p rp ours < <(gutt_shortcut_status)

  if [[ "$found" != "1" || -z "$p" ]]; then
    msgbox "No 'gutt' command was found on your PATH."
    return 2
  fi

  local why_block="" removable="0"

  case "$p" in
    "$HOME/.local/bin/gutt" | "$HOME/bin/gutt")
      removable="1"
      ;;
    "/usr/local/bin/gutt")
      why_block="This is a system location:
$p

GUTT will not remove system shortcuts. Please remove it manually (with sudo) if you really want it gone."
      ;;
    "/usr/bin/gutt" | "/bin/gutt" | "/sbin/gutt" | "/usr/sbin/gutt")
      why_block="This appears to be a system-managed binary:
$p

GUTT will not remove it."
      ;;
    *)
      why_block="This 'gutt' is in an unexpected location:
$p

For safety, GUTT will not remove it."
      ;;
  esac

  if [[ -n "$why_block" || "$removable" != "1" ]]; then
    msgbox "$why_block"
    return 0
  fi
  local warn=""
  if [[ "$ours" != "1" ]]; then
    warn="⚠ Note: This 'gutt' does not appear to point at the current GUTT instance.

"
  fi

  if ! yesno "${warn}🧹 Remove 'gutt'

Remove this shortcut?

$p"; then
    return 0
  fi

  local _rc
  set +e
  rm -f -- "$p" 2>/dev/null
  _rc=$?
  set -e

  if [[ $_rc -ne 0 ]]; then
    msgbox "❌ Failed to remove (rc=$_rc).

Path:
$p"
    return 0
  fi

  hash -r 2>/dev/null || true
  msgbox "✅ Removed.

Path:
$p"
  return 0
}

gutt_manage_path_menu() {
  local found p rp ours
  local status_label cmd_path

  while true; do
local state
state="$(gutt_path_integration_state)"

status_label="Not installed"
cmd_path="not found"

case "$state" in
  INSTALLED)
    status_label="Installed (this GUTT)"
    cmd_path="$(command -v gutt 2>/dev/null || echo "gutt")"
    ;;
  FOREIGN)
    status_label="Foreign command"
    cmd_path="$(command -v gutt 2>/dev/null || echo "gutt")"
    ;;
  PARTIAL)
    status_label="Wrapper present (NOT on PATH)"
    if [[ -x "$HOME/.local/bin/gutt" ]]; then
      cmd_path="$HOME/.local/bin/gutt"
    elif [[ -x "$HOME/bin/gutt" ]]; then
      cmd_path="$HOME/bin/gutt"
    else
      cmd_path="not found"
    fi
    ;;
  UNINSTALLED|*)
    status_label="Not installed"
    cmd_path="not found"
    ;;
esac

    local hdr
    hdr=$'Status: '"$status_label"$'
Command: '"$cmd_path"$'

Choose an action:'

    # Phase E: detect legacy/unmanaged PATH edits (report-first)
    local sh rcfile health unmanaged warn
    sh="$(gutt_detect_user_shell)"
    rcfile="$(gutt_path_rc_file_for_shell)"
    health="$(gutt_path_managed_block_health "$rcfile")"
    unmanaged="$(gutt_path_scan_unmanaged_lines "$rcfile")"
    warn=""
    if [[ "$health" == "MULTIPLE" || "$health" == "MALFORMED" ]]; then
      warn+=$'
⚠ Managed PATH block markers need attention (run Scan).'
    fi
    if [[ -n "$unmanaged" ]]; then
      warn+=$'
⚠ Legacy/unmanaged .local/bin PATH edits detected (run Scan).'
    fi
    if [[ -n "$warn" ]]; then
      hdr+="$warn"
    fi

    local usr_desc add_desc hint choice
    usr_desc="Install/update user shortcut (~/.local/bin/gutt)"
    add_desc="Add ~/.local/bin to PATH (managed block)"
    hint=""

    case "$state" in
      INSTALLED)
        usr_desc="Reinstall/update user shortcut (~/.local/bin/gutt)"
        hint=$'\n\n✅ PATH already resolves gutt. You are good.'
        ;;
      PARTIAL)
        add_desc="Add ~/.local/bin to PATH (fix PARTIAL state)"
        hint=$'\n\nNext step: add ~/.local/bin to PATH so "gutt" works in new shells.'
        ;;
      FOREIGN)
        usr_desc="Install user shortcut (~/.local/bin/gutt) (will not override foreign gutt)"
        hint=$'\n\n⚠ A different "gutt" is on PATH. GUTT will not overwrite it.'
        ;;
      UNINSTALLED)
        hint=$'\n\nTip: install the shortcut, then add ~/.local/bin to PATH if needed.'
        ;;
    esac

    choice="$(menu "$APP_NAME $VERSION" "🔗 Manage PATH integration

$hdr$hint" \
      "USR"    "$usr_desc" \
      "ADD"    "$add_desc" \
      "SCAN"   "Scan shell config for legacy/unmanaged PATH edits" \
      "REPAIR" "Repair managed PATH block (between markers)" \
      "PURGE"  "Recovery: purge and rebuild managed PATH block" \
      "REM"    "Remove shortcut (restart terminal)" \
      "RMBLK"  "Remove managed PATH block (restart terminal)" \
      "HOW"    "Show manual guidance" \
      "BACK"   "Back")" || return 0

    case "$choice" in
      USR) gutt_run_action gutt_shortcut_install_user ;;
      ADD) gutt_run_action gutt_path_add_managed_block ;;
      SCAN) gutt_run_action gutt_path_show_scan_report ;;
      REPAIR) gutt_run_action gutt_path_repair_managed_block ;;
      PURGE) gutt_run_action gutt_path_purge_and_rebuild_managed_block ;;
      REM)
        local rc=0
        set +e
        gutt_shortcut_remove
        rc=$?
        set -e
        [[ $rc -eq 2 ]] && continue
        ;;

      RMBLK) gutt_run_action gutt_path_remove_managed_block ;;
      HOW)
        msgbox "Manual guidance (no writes)

User install:
  mkdir -p \"$HOME/.local/bin\"
  install -m 0755 <this-file> \"$HOME/.local/bin/gutt\"

If ~/.local/bin isn't on PATH:
  export PATH=\"\$HOME/.local/bin:\$PATH\"

Managed block (recommended):
  # >>> GUTT PATH >>>
  export PATH=\"\$HOME/.local/bin:\$PATH\"
  # <<< GUTT PATH <<<"
        ;;
      BACK) return 0 ;;
    esac
  done
}

action_settings_menu() {
  while true; do
    local pull_mode fetch_before_push recent_limit allow_backup
    pull_mode="$(cfg_get default_pull_mode ff-only)"
    fetch_before_push="$(cfg_get auto_fetch_before_push 1)"
    recent_limit="$(cfg_get recent_limit 10)"
    allow_backup="$(cfg_get offer_backup_tag_before_danger 1)"

    local state label
    state="$(gutt_path_integration_state)"
    label="$(gutt_path_integration_label "$state")"

    local choice
    choice="$(menu "$APP_NAME $VERSION" "Settings" \
      "PULL" "Default pull mode: $pull_mode" \
      "FETCH" "Auto fetch before push: $fetch_before_push" \
      "REC" "Recent repos limit: $recent_limit" \
      "TAG" "Offer backup tag before danger: $allow_backup" \
      "PATH" "$label" \
      "BACK" "Back")" || return 0

    case "$choice" in
      PULL)
        local pm rc=0 had_e=0
        [[ $- == *e* ]] && had_e=1
        set +e
        pm="$(whiptail --title "$APP_NAME $VERSION" --radiolist "Select default pull mode" 14 70 3 \
          "ff-only" "Fast-forward only" $( [[ "$pull_mode" == "ff-only" ]] && echo ON || echo OFF ) \
          "merge" "Merge (default)" $( [[ "$pull_mode" == "merge" ]] && echo ON || echo OFF ) \
          "rebase" "Rebase" $( [[ "$pull_mode" == "rebase" ]] && echo ON || echo OFF ) \
          3>&1 1>&2 2>&3)"
        rc=$?
        ((had_e)) && set -e
        [[ $rc -eq 0 ]] || continue
        cfg_set default_pull_mode "$pm"
        ;;
      FETCH)
        if [[ "$fetch_before_push" == "1" ]]; then cfg_set auto_fetch_before_push 0; else cfg_set auto_fetch_before_push 1; fi
        ;;
      REC)
        local rl
        rl="$(inputbox "Recent repos limit" "$recent_limit")" || continue
        [[ "$rl" =~ ^[0-9]+$ ]] || { msgbox "Must be a number."; continue; }
        cfg_set recent_limit "$rl"
        ;;
      TAG)
        if [[ "$allow_backup" == "1" ]]; then cfg_set offer_backup_tag_before_danger 0; else cfg_set offer_backup_tag_before_danger 1; fi
        ;;
      PATH)
        gutt_manage_path_menu
        ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Main loop
# -------------------------
# -----------------------------------------------------------------------------
# vNext Menu Scaffolding (parallel navigation layer)
# NOTE: This is menu-only wiring. Actions map to existing handlers to avoid
#       behaviour changes while the new structure is validated.
# -----------------------------------------------------------------------------


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

vnext_coming_soon() {
  msgbox "This vNext section is scaffolded but not wired yet.

(We are doing this surgically: menu first, behaviour later.)"
}

vnext_common_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Fast Lane (Common)\n\nRepo:\n$repo" \
      "STAT" "Status (summary)" \
      "PULL" "Pull (safe update)" \
      "COMM" "Commit (checkpoint)" \
      "PUSH" "Push" \
      "CFB"  "Create feature branch (from main)" \
      "SWB"  "Switch branch" \
      "SQM"  "Squash merge into main" \
      "TEST" "Run smoke tests" \
      "STSH" "Stash push (quick)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      STAT) gutt_run_action action_status_summary "$repo" ;;
      PULL) gutt_run_action action_pull_safe_update "$repo" ;;
      COMM) gutt_run_action action_checkpoint_commit "$repo" ;;
      PUSH) gutt_run_action vnext_push_menu "$repo" ;;
      CFB) gutt_run_action vnext_create_feature_branch "$repo" ;;
      SWB) gutt_run_action action_branch_switch "$repo" ;;
      SQM) gutt_run_action vnext_squash_merge_into_main "$repo" ;;
      TEST) gutt_run_action vnext_run_smoke_tests "$repo" ;;
      STSH) gutt_run_action action_stash_push_quick "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

vnext_status_info_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Status & Info\n\nRepo:\n$repo" \
      "DASH" "Dashboard (repo summary)" \
      "STAT" "Full status (porcelain + summary)" \
      "LOG"  "Log (graph, all branches, last 50)" \
      "DIFF" "Diff (unstaged / staged)" \
      "RMT"  "Remote info (origin/upstream URLs + tracking)" \
      "AHD" "Ahead/behind check (upstream)" \
      "BLC" "Current branch + last commit details" \
      "REP" "Repo details (paths + default branch)" \
      "UNTR" "Untracked / ignored summary" \
      "LOGS" "Log / diff menus" \
      "BACK" "Back")" || return 0

    case "$choice" in
      DASH) show_dashboard "$repo" ;; # repo summary dashboard
      STAT) gutt_run_action action_full_status "$repo" ;;
      LOG) gutt_run_action run_git_capture "$repo" git log --graph --oneline --decorate --all -n 50 ;;
      DIFF) gutt_run_action vnext_diff_menu "$repo" ;;
      RMT) gutt_run_action vnext_remote_info "$repo" ;;
      AHD) gutt_run_action vnext_ahead_behind "$repo" ;;
      BLC) gutt_run_action vnext_branch_last_commit_details "$repo" ;;
      UNTR) gutt_run_action vnext_untracked_summary "$repo" ;;
      REP) gutt_run_action vnext_repo_details "$repo" ;;
      LOGS) gutt_run_action action_log_menu "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

vnext_diff_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Diff

Repo:
$repo"       "UNST" "Unstaged diff (working tree)"       "STAG" "Staged diff (--staged)"       "BACK" "Back")" || return 0

    case "$choice" in
      UNST) gutt_run_action run_git_capture "$repo" git diff ;;
      STAG) gutt_run_action run_git_capture "$repo" git diff --staged ;;
      BACK) return 0 ;;
    esac
  done
}


vnext_branch_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Branch

Repo:
$repo

Safe branch visibility tools first." \
      "LST" "List branches" \
      "NEW" "Create branch" \
      "SWI" "Switch branch" \
      "REN" "Rename current branch" \
      "DEL" "Delete branch (guarded)" \
      "PRN" "Prune remote-tracking branches (guarded)" \
      "LEG" "Legacy branch menu (advanced)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      LST) gutt_run_action vnext_list_branches "$repo" ;;
      NEW) gutt_run_action vnext_create_branch "$repo" ;;
      SWI) gutt_run_action action_branch_switch "$repo" ;;
      REN) gutt_run_action vnext_rename_current_branch "$repo" ;;
      UPT) gutt_run_action vnext_upstream_tracking "$repo" ;;
      DEL) gutt_run_action vnext_delete_branch "$repo" ;;
      PRN) gutt_run_action vnext_prune_remote_tracking "$repo" ;;
      LEG) gutt_run_action action_branch_menu "$repo" ;;
      BACK) return 0 ;;
    esac
  done
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

vnext_commit_menu() {
  local repo="$1"
  # Reuse existing commit menu
  action_commit_menu "$repo"
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

vnext_sync_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Sync (Pull/Push/Fetch)\n\nRepo:\n$repo" \
      "HLTH" "Upstream health (read-only)" \
      "PULL" "Pull (fast-forward only)" \
      "FETC" "Fetch" \
      "PUSH" "Push" \
      "UPST" "Set / view upstream" \
      "FFPS" "Force push (with lease) (guarded)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      HLTH) gutt_run_action vnext_upstream_health_view "$repo" ;;
      PULL) gutt_run_action action_pull_safe_update "$repo" ;;
      FETC) gutt_run_action action_fetch "$repo" ;;
      PUSH) gutt_run_action vnext_push_menu "$repo" ;;
      UPST) gutt_run_action action_set_upstream "$repo" ;;
      FFPS) gutt_run_action action_force_push "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

vnext_merge_rebase_menu() {
  local repo="$1"
  # Reuse existing merge/rebase menu
  action_merge_menu "$repo"
}

vnext_stash_menu() {
  local repo="$1"
  # Reuse existing stash menu
  action_stash_menu "$repo"
}

vnext_tags_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Tags & Known-Good (vNext scaffold)\n\nRepo:\n$repo" \
      "LIST" "List tags" \
      "MKOK" "Mark current as known-good" \
      "CRAT" "Create annotated tag" \
      "DELT" "Delete local tag (guarded)" \
      "PUSH" "Push tag to origin" \
      "PUSA" "Push all tags" \
      "BACK" "Back")" || return 0

    case "$choice" in
      LIST) gutt_run_action vnext_list_tags "$repo" ;;
      MKOK) gutt_run_action vnext_mark_known_good "$repo" ;;
      CRAT) gutt_run_action vnext_create_annotated_tag "$repo" ;;
      DELT) gutt_run_action vnext_delete_local_tag "$repo" ;;
      PUSH) gutt_run_action vnext_push_tag_to_origin "$repo" ;;
      PUSA) gutt_run_action vnext_push_all_tags "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

vnext_hygiene_menu() {
  local repo="$1"

  # Phase 10.1 (read-only): Hygiene & Cleanup summaries
  while true; do
    local choice
    choice="$(menu "Hygiene & Cleanup (read-only)" "Read-only hygiene views\n\nChoose an action" \
      "SUM"   "Show untracked / ignored / junk folders summary" \
      "EXP"   "Export hygiene report to a text file" \
      "REST"  "Restore file(s) (discard unstaged changes)" \
      "CLEAN" "Clean untracked files/dirs (guarded)" \
      "BACK"  "Back")" || return 0

    case "$choice" in
      SUM) gutt_run_action vnext_hygiene_cleanup_summary "$repo" ;;
      EXP) gutt_run_action vnext_hygiene_export_report "$repo" ;;
      REST) gutt_run_action vnext_hygiene_restore_files "$repo" ;;
      CLEAN) gutt_run_action vnext_hygiene_clean_untracked "$repo" ;;
      BACK)  return 0 ;;
    esac
  done
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

vnext_recovery_danger_menu() {
  local repo="$1"

  # Phase 9.1 scaffold: Recovery helpers live here, with the existing Danger Zone kept intact.
  # No behaviour changes unless the user explicitly chooses a new Recovery placeholder item.
  while true; do
    local choice
    choice="$(menu "Recovery & Dangerous" "Recovery helpers

Choose an action" \
      "KGTAGS" "Show known-good tags" \
      "CHECK"  "Show recovery checklist" \
      "GOKG"   "Go to known-good tag (guided)" \
      "BRKG"   "Recover by branching (shortcut)" \
      "EMERG"  "Emergency: last 20 commits + safe revert tips" \
      "DANG"   "Danger Zone (existing menu)" \
      "BACK"   "Back")" || return 0

    case "$choice" in
      KGTAGS)
        vnext_show_known_good_tags "$repo"
        ;;
      GOKG)
        vnext_go_to_known_good_tag "$repo"
        ;;
      BRKG)
        vnext_recover_by_branching "$repo"
        ;;
      CHECK)
        vnext_show_recovery_checklist "$repo"
        ;;
      EMERG)
        vnext_show_emergency_revert_notes "$repo"
        ;;
      DANG)
        action_danger_menu "$repo"
        ;;
      BACK)
        return 0
        ;;
    esac
  done
}

vnext_help_settings_menu() {
  local repo="$1"
  # Reuse existing settings/help/about menu
  action_settings_menu "$repo"
}

vnext_main_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "vNext Menu (parallel)\n\nRepo:\n$repo\n\nChoose a category" \
      "FAST" "Common (Fast Lane)" \
      "INFO" "Status & Info" \
      "BRAN" "Branch" \
      "COMM" "Commit" \
      "SYNC" "Sync (Pull/Push/Fetch)" \
      "MERG" "Merge & Rebase" \
      "STSH" "Stash" \
      "TAGS" "Tags & Known-Good (scaffold)" \
      "HYG"  "Hygiene & Cleanup" \
      "DANG" "Recovery & Dangerous" \
      "SET"  "Settings / Help / About" \
      "BACK" "Back to classic menu")" || return 0

    case "$choice" in
      FAST) gutt_run_action vnext_common_menu "$repo" ;;
      INFO) gutt_run_action vnext_status_info_menu "$repo" ;;
      BRAN) gutt_run_action vnext_branch_menu "$repo" ;;
      COMM) gutt_run_action vnext_commit_menu "$repo" ;;
      SYNC) gutt_run_action vnext_sync_menu "$repo" ;;
      MERG) gutt_run_action vnext_merge_rebase_menu "$repo" ;;
      STSH) gutt_run_action vnext_stash_menu "$repo" ;;
      TAGS) gutt_run_action vnext_tags_menu "$repo" ;;
      HYG) gutt_run_action vnext_hygiene_menu "$repo" ;;
      DANG) gutt_run_action vnext_recovery_danger_menu "$repo" ;;
      SET) gutt_run_action vnext_help_settings_menu "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

main_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Repo:\n$repo\n\nChoose an action" \
      "DASH" "Dashboard (repo summary)" \
      "STAT" "Git status" \
      "STAG" "Stage / unstage / discard" \
      "COMM" "Commit / amend" \
      "STSH" "Stash" \
      "BRAN" "Branches" \
      "MERG" "Merge / Rebase" \
      "REM"  "Remotes" \
      "LOG"  "Logs / diffs" \
      "HYG"  "Hygiene assistant" \
      "PULL" "Pull (mode from config)" \
      "PUSH" "Push" \
      "UPST" "Set upstream" \
      "VNX"  "vNext menu (new structure)" \
      "DANG" "Danger zone" \
      "PATH" "Manage PATH integration (gutt shortcut)" \
      "SETT" "Settings" \
      "SWCH" "Switch repo" \
      "QUIT" "Exit")" || return 0

    case "$choice" in
      DASH) gutt_run_action show_dashboard "$repo" ;;
      VNX) gutt_run_action vnext_main_menu "$repo" ;;
      STAT) gutt_run_action action_status "$repo" ;;
      STAG) gutt_run_action action_stage_menu "$repo" ;;
      COMM) gutt_run_action action_commit_menu "$repo" ;;
      STSH) gutt_run_action action_stash_menu "$repo" ;;
      BRAN) gutt_run_action action_branch_menu "$repo" ;;
      MERG) gutt_run_action action_merge_menu "$repo" ;;
      REM) gutt_run_action action_remote_menu "$repo" ;;
      LOG) gutt_run_action action_log_menu "$repo" ;;
      HYG) gutt_run_action action_hygiene_menu "$repo" ;;
      PULL) gutt_run_action action_pull_safe_update "$repo" ;;
      PUSH) gutt_run_action vnext_push_menu "$repo" ;;
      UPST) gutt_run_action action_set_upstream "$repo" ;;
      DANG) gutt_run_action action_danger_menu "$repo" ;;
      PATH) gutt_run_action gutt_manage_path_menu ;;
      SETT) gutt_run_action action_settings_menu ;;
      SWCH)
        local newrepo
        newrepo="$(select_repo)" || continue
        repo="$newrepo"
        ;;
      QUIT) return 0 ;;
    esac
  done
}

# -------------------------
# Beginner / Advanced mode scaffold (UX.1)
#
# IMPORTANT:
# - Advanced mode must remain functionally identical to pre-UX GUTT.
# - Beginner/Advanced is a UI/view layer only (menus + wrappers).
# - No existing action functions are modified by this scaffold.
# -------------------------


# -------------------------
# Beginner wrappers (UX.2 - UX.5)
# Wrapper-only: reuse existing helpers/flows, no new Git logic.
# -------------------------

beginner_get_info() {
  local repo="$1"
  show_dashboard "$repo"
}

beginner_see_what_changed() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Beginner: See what changed\n\nRepo:\n$repo\n\nChoose what to view (read-only)" \
      "QSUM" "Quick summary (status + diff --stat)" \
      "DIFF" "Full diff (working tree vs index/HEAD)" \
      "UPST" "Diff vs upstream (if set)" \
      "LOGS" "Logs & diffs menu (advanced view, still read-only)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      QSUM)
        run_git_capture "$repo" git status
        run_git_capture "$repo" git diff --stat
        ;;
      DIFF)
        run_git_capture "$repo" git diff
        ;;
      UPST)
        action_diff_upstream "$repo"
        ;;
      LOGS)
        action_log_menu "$repo"
        ;;
      BACK) return 0 ;;
    esac
  done
}

beginner_save_checkpoint() {
  local repo="$1"
  msgbox "Beginner: Save a checkpoint" "This creates a local commit (a safe checkpoint).\n\nIt does not push anything online and it does not change your working files.\n\nAll confirmations default to NO."
  vnext_mark_known_good "$repo"
}

beginner_upload_changes() {
  local repo="$1"
  msgbox "Beginner: Upload my changes" "We'll check what will be pushed, show you a clear summary, then (only if you confirm) push to your remote.\n\nNothing is uploaded unless you confirm.\n\nAll confirmations default to NO."
  action_push "$repo"
}

beginner_download_updates() {
  local repo="$1"
  msgbox "Beginner: Download updates" "We'll fetch and pull updates safely, and we'll show you what's going to change before anything is applied.\n\nNothing is changed unless you confirm.\n\nAll confirmations default to NO."
  action_pull "$repo"
}

beginner_start_new_work() {
  local repo="$1"
  msgbox "Beginner: Start a new piece of work" "We'll help you create a new feature branch so you can work safely without touching main.\n\nNothing is changed unless you confirm.\n\nAll confirmations default to NO."
  vnext_create_feature_branch "$repo"
}

beginner_publish_cleanly_to_main() {
  local repo="$1"
  msgbox "Beginner: Publish cleanly to main" "This is a guided, safe path to get your work onto main (typically via squash merge) with checks along the way.\n\nNothing is changed unless you confirm.\n\nAll confirmations default to NO."
  vnext_squash_merge_into_main "$repo"
}

beginner_tidy_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Beginner: Tidy up files safely\n\nRepo:\n$repo\n\nSafe helpers only.\n\nNothing destructive is done from here." \
      "SCAN" "Show hygiene report" \
      "PREV" "Preview what 'git clean' would remove (dry-run)" \
      "IGN"  "Suggest/append .gitignore entries (guarded)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      SCAN)
        hygiene_scan "$repo"
        ;;
      PREV)
        msgbox "Dry-run only" "Next, we'll show a DRY-RUN preview.\n\nThis does not delete anything."
        run_git_capture "$repo" git clean -ndx
        ;;
      IGN)
        # This routes to existing helper. It may offer to append; user must confirm (default NO).
        gitignore_suggest "$repo"
        ;;
      BACK) return 0 ;;
    esac
  done
}

beginner_safety_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Beginner: Get back to safety\n\nRepo:\n$repo\n\nRecovery helpers (guarded).\n\nNo 'Danger Zone' here." \
      "CHECK" "Show recovery checklist" \
      "KGTAGS" "Show known-good tags" \
      "GOKG"   "Go to known-good tag (guided)" \
      "BRKG"   "Recover by branching (shortcut)" \
      "EMERG"  "Emergency: last 20 commits + safe revert tips" \
      "BACK"   "Back")" || return 0

    case "$choice" in
      CHECK) gutt_run_action vnext_show_recovery_checklist "$repo" ;;
      KGTAGS) gutt_run_action vnext_show_known_good_tags "$repo" ;;
      GOKG) gutt_run_action vnext_go_to_known_good_tag "$repo" ;;
      BRKG) gutt_run_action vnext_recover_by_branching "$repo" ;;
      EMERG) gutt_run_action vnext_show_emergency_revert_notes "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

beginner_main_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Beginner mode (Guided)\n\nRepo:\n$repo\n\nChoose an action" \
      "INFO" "Get info on the repo" \
      "CHNG" "See what changed" \
      "SAVE" "Save a checkpoint" \
      "UPLD" "Upload my changes to my repo" \
      "DOWN" "Download updates from my repo" \
      "WORK" "Start a new piece of work" \
      "PUBL" "Publish cleanly to main" \
      "TIDY" "Tidy up files safely" \
      "SAFE" "Help, I want to get back to safety" \
      "MORE" "More options (Advanced)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      INFO) gutt_run_action beginner_get_info "$repo" ;;
      CHNG) gutt_run_action beginner_see_what_changed "$repo" ;;
      SAVE) gutt_run_action beginner_save_checkpoint "$repo" ;;
      UPLD) gutt_run_action beginner_upload_changes "$repo" ;;
      DOWN) gutt_run_action beginner_download_updates "$repo" ;;
      WORK) gutt_run_action beginner_start_new_work "$repo" ;;
      PUBL) gutt_run_action beginner_publish_cleanly_to_main "$repo" ;;
      TIDY) gutt_run_action beginner_tidy_menu "$repo" ;;
      SAFE) gutt_run_action beginner_safety_menu "$repo" ;;
      MORE) return 2 ;;  # signal: jump into Advanced
      BACK) return 0 ;;
    esac
  done
}

mode_selector_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Choose mode\n\nRepo:\n$repo" \
      "BEG" "Beginner (Guided)" \
      "ADV" "Advanced (Full / Unchanged)" \
      "QUIT" "Exit")" || return 0

    case "$choice" in
      BEG)
        # beginner_main_menu may return 2 as a *signal* to jump into Advanced.
        # Guard non-zero returns under set -e so Cancel/Esc or the signal code
        # never hard-exits the script.
        local rc=0
        set +e
        beginner_main_menu "$repo"
        rc=$?
        set -e

        if [[ $rc -eq 2 ]]; then
          main_menu "$repo"
        elif [[ $rc -ne 0 ]]; then
          return 0
        fi
        ;;
      ADV) gutt_run_action main_menu "$repo" ;;
      QUIT) return 0 ;;
    esac
  done
}

startup_repo_menu() {
  # Repo-first startup phase.
  # Repo-dependent modes must not be entered until a repo is explicitly confirmed.
  # PATH management remains available without selecting a repo.
  local detected_repo="${1:-}"

  while true; do
    local state label
    state="$(gutt_path_integration_state)"
    label="$(gutt_path_integration_label "$state")"

    local prompt
    if [[ -n "$detected_repo" ]]; then
      prompt="Detected Git repo:\n\n$detected_repo\n\nChoose an action"
    else
      prompt="Not currently inside a Git repo.\n\nChoose an action"
    fi

    local choice
    if [[ -n "$detected_repo" ]]; then
      choice="$(menu "$APP_NAME $VERSION" "$prompt" \
        "USE" "Use detected repo" \
        "REPO" "Select a different repo directory" \
        "PATH" "$label" \
        "QUIT" "Exit")" || return 1
    else
      choice="$(menu "$APP_NAME $VERSION" "$prompt" \
        "REPO" "Select a repo directory" \
        "PATH" "$label" \
        "QUIT" "Exit")" || return 1
    fi

    case "$choice" in
      USE)
        repos_bump_recent "$detected_repo"
        printf '%s\n' "$detected_repo"
        return 0
        ;;
      REPO)
        local repo=""
        repo="$(select_repo)" || continue
        printf '%s\n' "$repo"
        return 0
        ;;
      PATH)
        gutt_manage_path_menu
        ;;
      QUIT)
        return 1
        ;;
    esac
  done
}

main() {
  preflight

  local detected repo rc
  detected="$(git_repo_root "$PWD")"

  set +e
  repo="$(startup_repo_menu "$detected")"
  rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$repo" ]]; then
    return 0
  fi

  mode_selector_menu "$repo"
}

main "$@"

