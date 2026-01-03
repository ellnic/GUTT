#!/usr/bin/env bash
# GUTT - Git User TUI Tool (v0.3.0)
# Safe, guided Git TUI using whiptail.
# Focus: common Git workflows + strong safeguards against destructive actions.
#
# v0.3.0 highlights:
# - remembers repos + settings in ~/.config/gutt/
# - refuses to run as root (v1 safety rule)
# - staging/commit/amend, branches, merge/rebase, stash, remotes, logs/diffs
# - hygiene assistant (.gitignore suggestions)
# - danger zone: reflog, reset, clean (dry-run first), force push (force-with-lease), "no paper trail" baseline rewrite

set -Eeuo pipefail

VERSION="v0.3.0"
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
  if grep -qE "^[[:space:]]*${key}=" "$CFG_FILE"; then
    sed -i "s|^[[:space:]]*${key}=.*$|${key}=${val}|" "$CFG_FILE"
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
msgbox() { whiptail --title "$APP_NAME $VERSION" --msgbox "$1" 18 80 3>&1 1>&2 2>&3; }

inputbox() {
  local prompt="$1" default="${2:-}"
  whiptail --title "$APP_NAME $VERSION" --inputbox "$prompt" 10 78 "$default" 3>&1 1>&2 2>&3
}

menu() {
  local title="$1" text="$2"
  shift 2
  whiptail --title "$title" --menu "$text" 20 90 12 "$@" 3>&1 1>&2 2>&3
}

yesno() { whiptail --title "$APP_NAME $VERSION" --yesno "$1" 12 78 3>&1 1>&2 2>&3; }

textbox() { whiptail --title "$APP_NAME $VERSION" --textbox "$1" 22 90 3>&1 1>&2 2>&3; }

# -------------------------
# Git helpers (safe wrappers)
# -------------------------
run_git_capture() {
  # Usage: run_git_capture <repo> <command...>
  local repo="$1"; shift
  local tmp
  tmp="$(mktemp)"
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
  local tmp; tmp="$(mktemp)"
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

  tmp="$(mktemp)"
  (cd "$repo" && git switch -c "$branch" >/dev/null 2>"$tmp") || (cd "$repo" && git checkout -b "$branch" >/dev/null 2>"$tmp") || {
    textbox "$tmp"
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"

  local sum; sum="$(mktemp)"
  repo_summary "$repo" > "$sum"
  textbox "$sum"
  rm -f "$sum"
}

vnext_run_smoke_tests() {
  local repo="$1"
  local tmp rc=0
  tmp="$(mktemp)"

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
# vNext: Tags & Releases
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
  local tmp
  tmp="$(mktemp)"

  (cd "$repo" && git for-each-ref --sort=-creatordate \
    --format='%(refname:short)\t%(objectname:short)\t%(creatordate:short)\t%(subject)' \
    refs/tags) >"$tmp" 2>&1 || true

  if [[ ! -s "$tmp" ]]; then
    echo "No tags found." >"$tmp"
  fi

  textbox "$tmp"
  rm -f "$tmp"
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

  tmp="$(mktemp)"
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
  local ts default_tag tag msg tmp

  ts="$(date +%Y%m%d-%H%M)"
  default_tag="gutt/known-good-$ts"

  tag="$(inputbox "Mark current commit as known-good\n\nEnter tag name:" "$default_tag")" || return 0
  tag="${tag## }"; tag="${tag%% }"

  if ! validate_tag_name "$tag"; then
    msgbox "Invalid tag name:\n\n$tag"
    return 0
  fi

  msg="$(inputbox "Tag message (annotation):" "Known-good checkpoint")" || return 0

  tmp="$(mktemp)"
  (cd "$repo" && git tag -a "$tag" -m "$msg") >"$tmp" 2>&1 || true
  if git_tag_exists "$repo" "$tag"; then
    echo -e "Created known-good tag:\n\n$tag\n" >"$tmp"
    textbox "$tmp"
  else
    textbox "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"

  if have_origin_remote "$repo"; then
    if whiptail --title "$APP_NAME $VERSION" --yesno --defaultno \
      "Push this tag to origin now?\n\nTag: $tag" 12 78 3>&1 1>&2 2>&3; then
      run_git_capture "$repo" git push origin "$tag"
    fi
  else
    msgbox "No origin remote found.\n\nTag was created locally only."
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

  tmp="$(mktemp)"
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
  local tmp
  tmp="$(mktemp)"
  repo_summary "$repo" > "$tmp"
  whiptail --title "$APP_NAME $VERSION" --yesno "DANGER: $action\n\n$(cat "$tmp")\n\nProceed?" 22 90 3>&1 1>&2 2>&3
  local rc=$?
  rm -f "$tmp"
  return $rc
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
    whiptail --title "$APP_NAME $VERSION" --msgbox \
"GUTT should not be run as root.

Running Git as root can:
 - create root-owned files in your repo
 - break your normal Git workflow
 - cause permission issues later

Please re-run GUTT as a normal user.

Exiting." 16 72 3>&1 1>&2 2>&3
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
  tmp="$(mktemp)"
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
  tmp="$(mktemp)"
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

action_pull_safe_update() {
  local repo="$1"
  local branch upstream tmpf rc

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

  # Step 1: fetch first (explicit, safe update).
  tmpf="$(mktemp)"
  (cd "$repo" && git fetch --all --prune) >"$tmpf" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    textbox "$tmpf"
    rm -f "$tmpf"
    msgbox "Fetch failed. Pull aborted."
    return $rc
  fi
  rm -f "$tmpf"

  # Step 2: fast-forward only merge from upstream.
  tmpf="$(mktemp)"
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
    tmpf="$(mktemp)"
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
  tmpp="$(mktemp)"
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
  local branch remote
  branch="$(git_current_branch "$repo")"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    msgbox "Cannot set upstream on a detached HEAD."
    return 1
  fi
  remote="$(cd "$repo" && git remote 2>/dev/null | head -n1 || true)"
  if [[ -z "$remote" ]]; then
    msgbox "No remotes found. Add a remote first."
    return 1
  fi
  local target="${remote}/${branch}"
  if yesno "Set upstream for '$branch' to:\n\n$target\n\nProceed?" ; then
    run_git_capture "$repo" git push --set-upstream "$remote" "$branch"
  fi
}

# -------------------------
# Stage / Commit
# -------------------------
action_stage_by_file() {
  local repo="$1"
  local tmp; tmp="$(mktemp)"
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
  selected="$(whiptail --title "$APP_NAME $VERSION" --checklist "Select files to stage" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)" || return 0
  # shellcheck disable=SC2086
  (cd "$repo" && eval "git add $selected") || true
}

action_unstage_by_file() {
  local repo="$1"
  local tmp; tmp="$(mktemp)"
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

  local selected
  selected="$(whiptail --title "$APP_NAME $VERSION" --checklist "Select files to unstage" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)" || return 0
  # shellcheck disable=SC2086
  (cd "$repo" && eval "git restore --staged $selected") || true
}

action_discard_file() {
  local repo="$1"
  local tmp; tmp="$(mktemp)"
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

  local pick
  pick="$(whiptail --title "$APP_NAME $VERSION" --menu "Select a file to discard changes (restore from HEAD). DANGER." 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)" || return 0

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
  local msg
  msg="$(inputbox "Commit message" "")" || return 1
  [[ -n "$msg" ]] || { msgbox "Empty commit message refused."; return 1; }
  run_git_capture "$repo" git commit -m "$msg"
}

action_checkpoint_commit() {
  local repo="$1"
  local staged
  staged="$(cd "$repo" && git diff --cached --name-only 2>/dev/null | head -n1 || true)"
  if [[ -z "$staged" ]]; then
    msgbox "No staged changes.\n\nStage files first."
    return 1
  fi

  local msg
  msg="$(inputbox "Checkpoint commit message (WIP)" "WIP: ")" || return 1

  # Trim whitespace for emptiness checks
  local msg_trim
  msg_trim="${msg//[[:space:]]/}"

  # If user leaves it blank (or just "WIP:"), pick a safe default.
  if [[ -z "$msg_trim" || "$msg_trim" == "WIP:" ]]; then
    msg="WIP checkpoint"
  fi

  run_git_capture "$repo" git commit -m "$msg"
}


action_amend() {
  local repo="$1"
  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }
  if ! yesno "Amend the last commit?\n\nThis rewrites history.\n\nProceed?" ; then
    return 0
  fi
  run_git_capture "$repo" git commit --amend
}

action_reword_last() {
  local repo="$1"
  git_is_detached "$repo" && { msgbox "Detached HEAD."; return 1; }
  local msg
  msg="$(inputbox "New message for last commit" "")" || return 1
  [[ -n "$msg" ]] || { msgbox "Empty message refused."; return 1; }
  if ! yesno "Rewrite last commit message?\n\nThis rewrites history.\n\nProceed?" ; then
    return 0
  fi
  run_git_capture "$repo" git commit --amend -m "$msg"
}

action_commit_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Commit (repo: $repo)" \
      "COM" "Commit (requires staged changes)" \
      "WIP" "Checkpoint (WIP) commit" \
      "AMD" "Amend last commit" \
      "MSG" "Edit last commit message only" \
      "BACK" "Back")" || return 0
    case "$choice" in
      COM) action_commit "$repo" ;;
      WIP) action_checkpoint_commit "$repo" ;;
      AMD) action_amend "$repo" ;;
      MSG) action_reword_last "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Stash
# -------------------------
stash_pick() {
  local repo="$1"
  local tmp; tmp="$(mktemp)"
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
  whiptail --title "$APP_NAME $VERSION" --menu "Select a stash" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3
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

  tmp="$(mktemp)"
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
  local tmp; tmp="$(mktemp)"
  (cd "$repo" && git branch --format='%(refname:short)') >"$tmp" 2>/dev/null || true
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  local items=()
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    items+=("$b" "")
  done <"$tmp"
  rm -f "$tmp"
  whiptail --title "$APP_NAME $VERSION" --menu "Select a branch" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3
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

  local tmp; tmp="$(mktemp)"
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

  local choice
  choice="$(whiptail --title "$APP_NAME $VERSION" --menu "Select a branch

Current: $cur" 22 90 12 "${items[@]}" 3>&1 1>&2 2>&3)" || return 0
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
  local tmp; tmp="$(mktemp)"
  (cd "$repo" && git remote) >"$tmp" 2>/dev/null || true
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  local items=()
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    items+=("$r" "")
  done <"$tmp"
  rm -f "$tmp"
  whiptail --title "$APP_NAME $VERSION" --menu "Select a remote" 18 70 10 "${items[@]}" 3>&1 1>&2 2>&3
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

  local tmp; tmp="$(mktemp)"
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
  local tmp; tmp="$(mktemp)"
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
  local tmp; tmp="$(mktemp)"
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

  local mode phrase u
  mode="$(cfg_get force_push_mode force-with-lease)"
  phrase="$(cfg_get confirm_phrase_forcepush OVERWRITE REMOTE)"
  u="$(git_upstream "$repo")"
  [[ -n "$u" ]] || { msgbox "No upstream set.\n\nSet upstream first."; return 1; }

  local tmp; tmp="$(mktemp)"
  {
    echo "About to FORCE PUSH (mode: --$mode)"
    echo
    echo "Upstream: $u"
    echo "Local HEAD:   $(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || true)"
    echo "Remote HEAD:  $(cd "$repo" && git rev-parse --short "$u" 2>/dev/null || true)"
    echo
    echo "This can overwrite remote history."
  } >"$tmp"
  textbox "$tmp"
  rm -f "$tmp"

  confirm_phrase "Final confirmation required.\n\nForce pushing can overwrite remote history." "$phrase" || { msgbox "Cancelled."; return 0; }
  danger_preflight "$repo" "Force push to $u" || return 0
  offer_backup_tag "$repo"
  run_git_capture "$repo" git push --"$mode"
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
  confirm_phrase "This rewrites local history.\n\nIf remote has commits, you will also need Force Push.\n\nContinue?" "$phrase" || { msgbox "Cancelled."; return 0; }

  local tmp; tmp="$(mktemp)"
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
      RFL) run_git_capture "$repo" git reflog -n 30 ;;
      RST) action_reset_menu "$repo" ;;
      CLN) action_clean_untracked "$repo" ;;
      FRC) action_force_push "$repo" ;;
      NOP) action_no_paper_trail "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

# -------------------------
# Settings
# -------------------------
action_settings_menu() {
  while true; do
    local pull_mode fetch_before_push recent_limit allow_backup
    pull_mode="$(cfg_get default_pull_mode ff-only)"
    fetch_before_push="$(cfg_get auto_fetch_before_push 1)"
    recent_limit="$(cfg_get recent_limit 10)"
    allow_backup="$(cfg_get offer_backup_tag_before_danger 1)"

    local choice
    choice="$(menu "$APP_NAME $VERSION" "Settings" \
      "PULL" "Default pull mode: $pull_mode" \
      "FETCH" "Auto fetch before push: $fetch_before_push" \
      "REC" "Recent repos limit: $recent_limit" \
      "TAG" "Offer backup tag before danger: $allow_backup" \
      "BACK" "Back")" || return 0

    case "$choice" in
      PULL)
        local pm
        pm="$(whiptail --title "$APP_NAME $VERSION" --radiolist "Select default pull mode" 14 70 3 \
          "ff-only" "Fast-forward only" $( [[ "$pull_mode" == "ff-only" ]] && echo ON || echo OFF ) \
          "merge" "Merge (default)" $( [[ "$pull_mode" == "merge" ]] && echo ON || echo OFF ) \
          "rebase" "Rebase" $( [[ "$pull_mode" == "rebase" ]] && echo ON || echo OFF ) \
          3>&1 1>&2 2>&3)" || continue
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
  logtmp="$(mktemp)"
  (cd "$repo" && git log --oneline --decorate "$main..$branch" 2>/dev/null) >"$logtmp" || true

  if [[ ! -s "$logtmp" ]]; then
    rm -f "$logtmp"
    msgbox "Nothing to squash-merge.\n\nNo commits found in:\n  $main..$branch"
    return 0
  fi

  tmp="$(mktemp)"
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
    tmp2="$(mktemp)"
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
  tmp2="$(mktemp)"
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

  tmp2="$(mktemp)"
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
    action_push "$repo"
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
      STAT) action_status_summary "$repo" ;;
      PULL) action_pull_safe_update "$repo" ;;
      COMM) action_checkpoint_commit "$repo" ;;
      PUSH) action_push "$repo" ;;
      CFB)  vnext_create_feature_branch "$repo" ;;
      SWB)  action_branch_switch "$repo" ;;
      SQM)  vnext_squash_merge_into_main "$repo" ;;
      TEST) vnext_run_smoke_tests "$repo" ;;
      STSH) action_stash_push_quick "$repo" ;;
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
      DASH) action_show_commit "$repo" ;; # closest existing quick info
      STAT) action_full_status "$repo" ;;
      LOG)  run_git_capture "$repo" git log --graph --oneline --decorate --all -n 50 ;;
      DIFF) vnext_diff_menu "$repo" ;;
      RMT)  vnext_remote_info "$repo" ;;
      AHD) vnext_ahead_behind "$repo" ;;
      BLC)  vnext_branch_last_commit_details "$repo" ;;
      UNTR) vnext_untracked_summary "$repo" ;;
      REP)  vnext_repo_details "$repo" ;;
      LOGS) action_log_menu "$repo" ;;
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
      UNST) run_git_capture "$repo" git diff ;;
      STAG) run_git_capture "$repo" git diff --staged ;;
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
      LST) vnext_list_branches "$repo" ;;
      NEW) vnext_create_branch "$repo" ;;
      SWI) action_branch_switch "$repo" ;;
      REN) vnext_rename_current_branch "$repo" ;;
      UPT) vnext_upstream_tracking "$repo" ;;
      DEL) vnext_delete_branch "$repo" ;;
      PRN) vnext_prune_remote_tracking "$repo" ;;
      LEG) action_branch_menu "$repo" ;;
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

  local tmp; tmp="$(mktemp)"
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
          tmp="$(mktemp)"
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

          rb="$(whiptail --title "$APP_NAME $VERSION" --menu "Select remote branch for upstream ($remote)" 20 78 12 "${items[@]}" 3>&1 1>&2 2>&3)" || continue
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
  tmp="$(mktemp)"

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
  tmp="$(mktemp)"
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
  tmp="$(mktemp)"
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
  tmp="$(mktemp)"
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
  tmp="$(mktemp)"
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

vnext_untracked_summary() {
  local repo="$1"
  local tmp
  tmp="$(mktemp)"
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
  rm -f "$tmp"
}



vnext_commit_menu() {
  local repo="$1"
  # Reuse existing commit menu
  action_commit_menu "$repo"
}

vnext_sync_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Sync (Pull/Push/Fetch)\n\nRepo:\n$repo" \
      "PULL" "Pull" \
      "PUSH" "Push" \
      "UPST" "Set / view upstream" \
      "FFPS" "Force push (with lease) (guarded)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      PULL) action_pull "$repo" ;;
      PUSH) action_push "$repo" ;;
      UPST) action_set_upstream "$repo" ;;
      FFPS) action_force_push "$repo" ;;
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
    choice="$(menu "$APP_NAME $VERSION" "Tags & Releases (vNext scaffold)\n\nRepo:\n$repo" \
      "LIST" "List tags" \
      "MKOK" "Mark current as known-good" \
      "CRAT" "Create annotated tag" \
      "DELT" "Delete local tag (guarded)" \
      "PUSH" "Push tag to origin" \
      "PUSA" "Push all tags" \
      "BACK" "Back")" || return 0

    case "$choice" in
      LIST) vnext_list_tags "$repo" ;;
      MKOK) vnext_mark_known_good "$repo" ;;
      CRAT) vnext_create_annotated_tag "$repo" ;;
      DELT) vnext_delete_local_tag "$repo" ;;
      PUSH) vnext_push_tag_to_origin "$repo" ;;
      PUSA) vnext_push_all_tags "$repo" ;;
      BACK) return 0 ;;
    esac
  done
}

vnext_hygiene_menu() {
  local repo="$1"
  # Reuse existing hygiene assistant menu
  action_hygiene_menu "$repo"
}

vnext_recovery_danger_menu() {
  local repo="$1"
  # Reuse existing danger menu
  action_danger_menu "$repo"
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
      "TAGS" "Tags & Releases (scaffold)" \
      "HYG"  "Hygiene & Cleanup" \
      "DANG" "Recovery & Dangerous" \
      "SET"  "Settings / Help / About" \
      "BACK" "Back to classic menu")" || return 0

    case "$choice" in
      FAST) vnext_common_menu "$repo" ;;
      INFO) vnext_status_info_menu "$repo" ;;
      BRAN) vnext_branch_menu "$repo" ;;
      COMM) vnext_commit_menu "$repo" ;;
      SYNC) vnext_sync_menu "$repo" ;;
      MERG) vnext_merge_rebase_menu "$repo" ;;
      STSH) vnext_stash_menu "$repo" ;;
      TAGS) vnext_tags_menu "$repo" ;;
      HYG)  vnext_hygiene_menu "$repo" ;;
      DANG) vnext_recovery_danger_menu "$repo" ;;
      SET)  vnext_help_settings_menu "$repo" ;;
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
      "SETT" "Settings" \
      "SWCH" "Switch repo" \
      "QUIT" "Exit")" || return 0

    case "$choice" in
      DASH) show_dashboard "$repo" ;;
      VNX)  vnext_main_menu "$repo" ;;
      STAT) action_status "$repo" ;;
      STAG) action_stage_menu "$repo" ;;
      COMM) action_commit_menu "$repo" ;;
      STSH) action_stash_menu "$repo" ;;
      BRAN) action_branch_menu "$repo" ;;
      MERG) action_merge_menu "$repo" ;;
      REM)  action_remote_menu "$repo" ;;
      LOG)  action_log_menu "$repo" ;;
      HYG)  action_hygiene_menu "$repo" ;;
      PULL) action_pull "$repo" ;;
      PUSH) action_push "$repo" ;;
      UPST) action_set_upstream "$repo" ;;
      DANG) action_danger_menu "$repo" ;;
      SETT) action_settings_menu ;;
      SWCH)
        local newrepo
        newrepo="$(select_repo)" || continue
        repo="$newrepo"
        ;;
      QUIT) return 0 ;;
    esac
  done
}

main() {
  preflight

  local repo=""
  repo="$(git_repo_root "$PWD")"
  if [[ -z "$repo" ]]; then
    repo="$(select_repo)" || exit 0
  else
    repos_bump_recent "$repo"
  fi

  main_menu "$repo"
}

main "$@"
