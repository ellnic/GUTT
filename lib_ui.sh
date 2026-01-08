#!/usr/bin/env bash
# lib_ui.sh - dialog/whiptail wrappers + safety friction (no git)


ui_file_has_non_ws() {
  local f="$1"
  [[ -r "$f" ]] || return 1
  grep -q "[^[:space:]]" "$f"
}
msgbox() {
  # Display-only helper: never allow whiptail return codes to trip errexit.
  [[ -z "${1//[[:space:]]/}" ]] && return 0
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
  # Guard: avoid blank dialog if called with zero menu entries.
  # Return 2 (back/cancel convention) rather than invoking whiptail.
  if [[ $# -eq 0 ]]; then
    return 2
  fi
  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  whiptail --title "$title" --menu "$text" 20 90 12 "$@" 3>&1 1>&2 2>&3
  rc=$?
  ((had_e)) && set -e
  return $rc
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

  if ! ui_file_has_non_ws "$file"; then
    return 0
  fi

  set +e
  whiptail --title "$title" --textbox "$file" 22 90 </dev/tty >/dev/tty 2>/dev/tty
  ((had_e)) && set -e
  return 0
}

run_git_capture() {
  # Usage: run_git_capture <repo> <command...>
  local repo="$1"; shift
  local tmp
  tmp="$(mktemp_gutt)"
  (cd "$repo" && "$@") >"$tmp" 2>&1 || true
  if ui_file_has_non_ws "$tmp"; then
    textbox "$tmp"
  fi
  rm -f "$tmp"
}

confirm_phrase() {
  # Usage: confirm_phrase "Prompt..." "PHRASE"
  local prompt="$1" phrase="$2"
  local got
  got="$(whiptail --title "$APP_NAME $VERSION" --inputbox "$prompt\n\nType exactly:\n$phrase" 12 78 "" 3>&1 1>&2 2>&3)" || return 1
  [[ "$got" == "$phrase" ]]
}
