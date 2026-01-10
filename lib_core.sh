#!/usr/bin/env bash
# lib_core.sh - core utilities, config, repo state, logging (no UI, no git history changes)

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
trap \'gutt_cleanup_tmpfiles\' EXIT


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

validate_branch_name() {
  # Usage: validate_branch_name <repo> <name>
  local repo="$1" name="$2"

  [[ -n "$name" ]] || return 1
  [[ "$name" != "main" && "$name" != "master" ]] || return 1
  [[ "$name" != "HEAD" ]] || return 1

  (cd "$repo" && git check-ref-format --branch "$name" >/dev/null 2>&1)
}

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

show_dashboard() {
  local repo="$1"
  local tmp
  tmp="$(mktemp_gutt)"
  repo_summary "$repo" > "$tmp"
  textbox "$tmp"
  rm -f "$tmp"
}

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

gutt_shortcut_status() {
  # Back-compat shim.
  # Outputs: found(0/1) path resolved_target is_ours(0/1)
  #
  # "is_ours" means:
  #   - the PATH-resolved gutt is a symlink, AND
  #   - it points to THIS repo's canonical entrypoint.
  local entry_real p cv tt link_target resolved ours="0" found="0"

  entry_real="$(gutt_self_realpath 2>/dev/null || true)"
  entry_real="$(readlink -f -- "$entry_real" 2>/dev/null || printf '%s' "$entry_real")"

  cv="$(command -v gutt 2>/dev/null || true)"
  tt="$(type -t gutt 2>/dev/null || true)"

  if [[ -n "$cv" ]]; then
    found="1"
    if [[ "$tt" != "file" && "$tt" != "keyword" ]]; then
      printf '1 %s "" 0\n' "$cv"
      return 0
    fi
    p="$cv"
  else
    # Not on PATH in this shell. Report a matching managed symlink if present.
    for p in /usr/local/bin/gutt "$HOME/.local/bin/gutt"; do
      if [[ -L "$p" ]]; then
        found="1"
        break
      fi
    done
    [[ "$found" == "1" ]] || { printf '0 "" "" 0\n'; return 0; }
  fi

  link_target=""
  resolved=""
  if [[ -L "$p" ]]; then
    link_target="$(readlink -- "$p" 2>/dev/null || true)"
    resolved="$(readlink -f -- "$p" 2>/dev/null || true)"
    if [[ -n "$entry_real" && -n "$resolved" && "$resolved" == "$entry_real" ]]; then
      ours="1"
    fi
  fi

  printf '%s %s %s %s\n' "$found" "$p" "${resolved:-}" "$ours"
  return 0
}

# Legacy shell detection helper (kept for now; may be removed later)
gutt_detect_user_shell() {
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

# Back-compat wrappers (the menu now uses gutt_path_install/remove directly).
gutt_shortcut_install_user() { gutt_path_install; }

gutt_shortcut_remove() { gutt_path_remove; }

