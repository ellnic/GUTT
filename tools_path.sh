#!/usr/bin/env bash
# tools_path.sh - PATH integration (explicit, symlink-based, non-invasive)
#
# Definition of "PATH integration":
#   Create a single executable entry called 'gutt' discoverable via:
#     command -v gutt
#
# This is implemented ONLY as a symlink pointing at this repo's canonical entrypoint.
# No shell rc-file editing. No PATH exports. No silent exits.

# Canonical entrypoint (single source of truth)
# Locked to: <repo_root>/gutt (the main router script).

_gutt_entry_realpath() {
  local entry="${__GUTT_DIR:-}"/gutt
  if [[ -z "${__GUTT_DIR:-}" || ! -e "$entry" ]]; then
    # Fallback: resolve from this file's dir (should not happen in normal runs)
    entry="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/gutt"
  fi
  readlink -f -- "$entry" 2>/dev/null || printf '%s\n' "$entry"
}

# Back-compat: other parts of GUTT call this name.
gutt_self_realpath() { _gutt_entry_realpath; }

_gutt_install_locations() {
  # Order matters (preferred first)
  printf '%s\n' \
    "/usr/local/bin/gutt" \
    "$HOME/.local/bin/gutt"
}

_gutt_first_writable_target() {
  local t dir
  while IFS= read -r t; do
    dir="$(dirname -- "$t")"
    if [[ -d "$dir" && -w "$dir" ]]; then
      printf '%s\n' "$t"
      return 0
    fi
  done < <(_gutt_install_locations)

  # User dir may not exist yet.
  if [[ -d "$HOME/.local" && ( ! -d "$HOME/.local/bin" ) && -w "$HOME/.local" ]]; then
    printf '%s\n' "$HOME/.local/bin/gutt"
    return 0
  fi

  return 1
}

_gutt_is_symlink_to_entry() {
  # Usage: _gutt_is_symlink_to_entry <path> <entry_real>
  local p="${1:-}" entry_real="${2:-}"
  [[ -n "$p" && -n "$entry_real" ]] || return 1
  [[ -L "$p" ]] || return 1

  local rp
  rp="$(readlink -f -- "$p" 2>/dev/null || true)"
  [[ -n "$rp" && "$rp" == "$entry_real" ]]
}

_gutt_path_status_compute() {
  # Emits:
  #   cmd_path|notfound
  #   cmd_type
  #   cmd_is_symlink(0/1)
  #   cmd_target (resolved) or blank
  #   summary (Installed and valid / Installed but stale / Installed but foreign / Not installed)
  local entry_real cmd_path cmd_type cmd_is_symlink cmd_target summary

  entry_real="$(_gutt_entry_realpath)"
  cmd_path="$(command -v gutt 2>/dev/null || true)"
  cmd_type="$(type -t gutt 2>/dev/null || true)"

  cmd_is_symlink=0
  cmd_target=""

  if [[ -n "$cmd_path" && ( "$cmd_type" == "file" || "$cmd_type" == "keyword" ) && -e "$cmd_path" ]]; then
    if [[ -L "$cmd_path" ]]; then
      cmd_is_symlink=1
      cmd_target="$(readlink -f -- "$cmd_path" 2>/dev/null || true)"
    fi
  fi

  # Decide summary
  summary="Not installed"

  if [[ -n "$cmd_path" ]]; then
    if [[ "$cmd_type" != "file" && "$cmd_type" != "keyword" ]]; then
      summary="Installed but foreign"
    elif [[ "$cmd_is_symlink" -eq 1 ]]; then
      if [[ -n "$cmd_target" && "$cmd_target" == "$entry_real" ]]; then
        summary="Installed and valid"
      else
        # It's a symlink but not to this repo's current entrypoint.
        # If it's in our install locations, call it stale, else foreign.
        case "$cmd_path" in
          "/usr/local/bin/gutt"|"$HOME/.local/bin/gutt") summary="Installed but stale" ;;
          *) summary="Installed but foreign" ;;
        esac
      fi
    else
      # Resolved to a real file (or a non-symlink). That's foreign.
      summary="Installed but foreign"
    fi
  else
    # Not on PATH. If a matching symlink exists in our locations, call it stale.
    local loc
    while IFS= read -r loc; do
      if _gutt_is_symlink_to_entry "$loc" "$entry_real"; then
        summary="Installed but stale"
        break
      fi
    done < <(_gutt_install_locations)
  fi

  printf '%s|%s|%s|%s|%s\n' \
    "${cmd_path:-notfound}" \
    "${cmd_type:-}" \
    "${cmd_is_symlink}" \
    "${cmd_target:-}" \
    "${summary}"
}

# --- Public API expected by UI ---

gutt_path_integration_state() {
  # Match the POA summary states.
  local parts summary
  parts="$(_gutt_path_status_compute)"
  summary="${parts##*|}"

  case "$summary" in
    "Installed and valid") echo "INSTALLED" ;;
    "Installed but stale") echo "STALE" ;;
    "Installed but foreign") echo "FOREIGN" ;;
    *) echo "UNINSTALLED" ;;
  esac
}

gutt_path_integration_label() {
  local st
  st="$(gutt_path_integration_state 2>/dev/null || true)"
  case "$st" in
    INSTALLED) echo "PATH integration: Installed and valid" ;;
    STALE)     echo "PATH integration: Installed but stale (repo moved?)" ;;
    FOREIGN)   echo "PATH integration: Installed but foreign" ;;
    *)         echo "PATH integration: Not installed" ;;
  esac
}

gutt_path_status() {
  # If whiptail is missing/broken, print plainly to terminal.
  if ! command -v whiptail >/dev/null 2>&1; then
    printf '\n[PATH integration] whiptail not found. Showing status in plain text.\n\n' >/dev/tty
    gutt_path_status_plain
    printf '\nInstall/remove requires the TUI (whiptail).\n' >/dev/tty
    return 0
  fi

  local parts cmd_path cmd_type cmd_is_symlink cmd_target summary entry_real
  entry_real="$(_gutt_entry_realpath)"
  parts="$(_gutt_path_status_compute)"
  IFS='|' read -r cmd_path cmd_type cmd_is_symlink cmd_target summary <<<"$parts"

  local msg
  msg="Canonical entrypoint:\n  $entry_real\n\n"
  msg+="command -v gutt:\n  ${cmd_path/notfound/not found}\n"

  if [[ "$cmd_path" != "notfound" ]]; then
    msg+="type -t gutt:\n  ${cmd_type:-unknown}\n\n"

    if [[ "$cmd_is_symlink" -eq 1 ]]; then
      msg+="Resolved command is a symlink:\n  yes\n"
      msg+="Symlink target (resolved):\n  ${cmd_target:-unknown}\n"
    else
      msg+="Resolved command is a symlink:\n  no\n"
    fi
  fi

  msg+="\nSummary:\n  $summary\n"

  msgbox "$msg"
  return 0
}

gutt_path_status_plain() {
  local parts cmd_path cmd_type cmd_is_symlink cmd_target summary entry_real
  entry_real="$(_gutt_entry_realpath)"
  parts="$(_gutt_path_status_compute)"
  IFS='|' read -r cmd_path cmd_type cmd_is_symlink cmd_target summary <<<"$parts"

  printf 'Canonical entrypoint: %s\n' "$entry_real" >/dev/tty
  printf 'command -v gutt:      %s\n' "${cmd_path/notfound/not found}" >/dev/tty
  if [[ "$cmd_path" != "notfound" ]]; then
    printf 'type -t gutt:         %s\n' "${cmd_type:-unknown}" >/dev/tty
    if [[ "$cmd_is_symlink" -eq 1 ]]; then
      printf 'symlink target:       %s\n' "${cmd_target:-unknown}" >/dev/tty
    fi
  fi
  printf 'summary:              %s\n' "$summary" >/dev/tty
}

gutt_path_install() {
  local entry_real target target_dir
  entry_real="$(_gutt_entry_realpath)"

  target="$(_gutt_first_writable_target || true)"
  if [[ -z "$target" ]]; then
    msgbox "❌ No writable install location found.\n\nTried:\n- /usr/local/bin/gutt (needs write access)\n- $HOME/.local/bin/gutt (needs write access)\n\nGUTT will not modify PATH or shell rc files."
    return 0
  fi

  target_dir="$(dirname -- "$target")"

  # Ensure user dir exists if chosen
  if [[ "$target" == "$HOME/.local/bin/gutt" ]]; then
    mkdir -p -- "$target_dir" 2>/dev/null || true
  fi

  # Preflight existing
  if [[ -e "$target" || -L "$target" ]]; then
    if _gutt_is_symlink_to_entry "$target" "$entry_real"; then
      msgbox "✅ Already installed.\n\n$target -> $entry_real"
      return 0
    fi

    local what="file"
    [[ -L "$target" ]] && what="symlink"
    local existing_target=""
    if [[ -L "$target" ]]; then
      existing_target="$(readlink -f -- "$target" 2>/dev/null || true)"
    fi

    msgbox "⚠ Refusing to overwrite existing entry.\n\nPath: $target\nType: $what\nSymlink target: ${existing_target:-n/a}\n\nWanted: symlink to\n  $entry_real"
    return 0
  fi

  if ! yesno "🔗 Install PATH integration\n\nCreate symlink:\n  $target\n-> $entry_real\n\nProceed?"; then
    return 2
  fi

  local rc=0
  set +e
  ln -s -- "$entry_real" "$target" 2>/dev/null
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    msgbox "❌ Failed to create symlink (rc=$rc).\n\nTarget:\n  $target\n\nEntry:\n  $entry_real"
    return 0
  fi

  hash -r 2>/dev/null || true
  msgbox "✅ Installed.\n\n$target -> $entry_real\n\nCheck:\n  command -v gutt\n  gutt"
  return 0
}

gutt_path_remove() {
  local entry_real removed_any=0
  entry_real="$(_gutt_entry_realpath)"

  local targets=()
  while IFS= read -r t; do targets+=("$t"); done < <(_gutt_install_locations)

  local matches=()
  local t
  for t in "${targets[@]}"; do
    if _gutt_is_symlink_to_entry "$t" "$entry_real"; then
      matches+=("$t")
    fi
  done

  if [[ ${#matches[@]} -eq 0 ]]; then
    msgbox "Nothing to remove.\n\nNo matching symlink found in:\n- /usr/local/bin/gutt\n- $HOME/.local/bin/gutt"
    return 0
  fi

  local msg="🧹 Remove PATH integration\n\nThis will remove ONLY symlinks that point to:\n  $entry_real\n\nRemove:\n"
  for t in "${matches[@]}"; do
    msg+="  - $t\n"
  done
  msg+="\nProceed?"

  if ! yesno "$msg"; then
    return 2
  fi

  local rc=0
  for t in "${matches[@]}"; do
    set +e
    rm -f -- "$t" 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      removed_any=1
    else
      msgbox "❌ Failed to remove (rc=$rc):\n\n$t"
      return 0
    fi
  done

  hash -r 2>/dev/null || true

  msgbox "✅ Removed.\n\nRe-check:\n  command -v gutt"
  GUTT_REQUIRE_RESTART=1
  return 0
}

gutt_manage_path_menu() {
  # Requirement: if whiptail is missing/fails, print status and exit visibly.
  if ! command -v whiptail >/dev/null 2>&1; then
    printf '\n[PATH integration] whiptail not found.\n' >/dev/tty
    gutt_path_status_plain
    printf '\nCannot open menu without whiptail.\n\n' >/dev/tty
    return 0
  fi

  while true; do
    local label choice
    label="$(gutt_path_integration_label)"

    choice="$(menu "$APP_NAME $VERSION" "PATH integration\n\n$label\n\n(Definition: command -v gutt finds one symlink to this repo.)" \
      "STAT" "Status (always safe)" \
      "INST" "Install" \
      "REM"  "Remove" \
      "BACK" "Back")" || return 0

    case "$choice" in
      STAT) gutt_run_action gutt_path_status ;;
      INST) gutt_run_action gutt_path_install ;;
      REM)  gutt_run_action gutt_path_remove ;;
      BACK) return 0 ;;
    esac
  done
}
