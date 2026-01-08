#!/usr/bin/env bash
# tools_path.sh - PATH integration (wrapper-based install/remove/status)

gutt_self_realpath() {
  readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s
' "${BASH_SOURCE[0]}"
}

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
