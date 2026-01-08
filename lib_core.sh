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
