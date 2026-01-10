#!/usr/bin/env bash
# lib_ui.sh - dialog/whiptail wrappers + safety friction (no git)

# -----------------------------------------------------------------------------
# Terminal-aware dialog sizing helpers (prevents off-screen cropping)
# -----------------------------------------------------------------------------

UI_SAFE_MARGIN=${UI_SAFE_MARGIN:-4}
UI_SAFE_MARGIN_H=${UI_SAFE_MARGIN_H:-4}
UI_MIN_W=${UI_MIN_W:-60}
UI_SOFT_MAX_W=${UI_SOFT_MAX_W:-110}

ui_term_dims() {
  local cols lines
  cols="$(tput cols 2>/dev/null || echo 80)"
  lines="$(tput lines 2>/dev/null || echo 24)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24
  UI_TERM_COLS="$cols"
  UI_TERM_LINES="$lines"
}

ui_clamp() {
  local v="$1" lo="$2" hi="$3"
  (( v < lo )) && v="$lo"
  (( v > hi )) && v="$hi"
  echo "$v"
}

ui_longest_line_len() {
  awk 'BEGIN{m=0} { if (length($0) > m) m=length($0) } END{ print m }'
}

ui_count_lines() {
  awk 'END{ print NR }'
}

ui_dims_from_text() {
  # Usage: ui_dims_from_text "<text>" "<min_h>" "<pad_w>" "<pad_h>"
  local text="$1" min_h="${2:-10}" pad_w="${3:-8}" pad_h="${4:-8}"
  ui_term_dims
  local cols=$UI_TERM_COLS lines=$UI_TERM_LINES

  local max_w=$(( cols - UI_SAFE_MARGIN ))
  local max_h=$(( lines - UI_SAFE_MARGIN_H ))
  (( max_w < 20 )) && max_w=20
  (( max_h < 8 )) && max_h=8

  local longest linecount desired_w desired_h soft_max
  longest="$(printf "%s" "$text" | ui_longest_line_len)"
  linecount="$(printf "%s" "$text" | ui_count_lines)"
  desired_w=$(( longest + pad_w ))
  desired_h=$(( linecount + pad_h ))

  soft_max=$UI_SOFT_MAX_W
  (( soft_max > max_w )) && soft_max=$max_w

  local w h
  w="$(ui_clamp "$desired_w" "$UI_MIN_W" "$soft_max")"
  h="$(ui_clamp "$desired_h" "$min_h" "$max_h")"
  echo "$h $w"
}

ui_menu_max_item_len() {
  local max=0 tag desc combined
  while [[ $# -ge 2 ]]; do
    tag="$1"; desc="$2"
    combined="${tag}  ${desc}"
    (( ${#combined} > max )) && max=${#combined}
    shift 2
  done
  echo "$max"
}

ui_dims_for_menu() {
  # Usage: ui_dims_for_menu "<text>" "<items_count>" "<menu_max_item_len>"
  local text="$1" items="$2" item_max="$3"
  ui_term_dims
  local cols=$UI_TERM_COLS lines=$UI_TERM_LINES

  local max_w=$(( cols - UI_SAFE_MARGIN ))
  local max_h=$(( lines - UI_SAFE_MARGIN_H ))
  (( max_w < 30 )) && max_w=30
  (( max_h < 12 )) && max_h=12

  local soft_max=$UI_SOFT_MAX_W
  (( soft_max > max_w )) && soft_max=$max_w

  local text_longest text_lines desired_w list_h desired_h w h
  text_longest="$(printf "%s" "$text" | ui_longest_line_len)"
  text_lines="$(printf "%s" "$text" | ui_count_lines)"

  desired_w=$(( (text_longest>item_max?text_longest:item_max) + 10 ))
  w="$(ui_clamp "$desired_w" "$UI_MIN_W" "$soft_max")"

  list_h="$items"
  (( list_h > 12 )) && list_h=12
  (( list_h < 3 )) && list_h=3

  desired_h=$(( text_lines + list_h + 8 ))
  h="$(ui_clamp "$desired_h" 14 "$max_h")"

  echo "$h $w $list_h"
}


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
  local h w
  read -r h w < <(ui_dims_from_text "$1" 10 8 8)
  if ! whiptail --title "$APP_NAME $VERSION" --msgbox "$1" "$h" "$w" </dev/tty >/dev/tty 2>/dev/tty; then
    printf "
%s

" "$1" >/dev/tty
  fi
  ((had_e)) && set -e
  return 0
}

inputbox() {
  local prompt="$1" default="${2:-}"
  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  local h w
  read -r h w < <(ui_dims_from_text "$prompt" 10 8 7)
  whiptail --title "$APP_NAME $VERSION" --inputbox "$prompt" "$h" "$w" "$default" 3>&1 1>&2 2>&3 </dev/tty
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
  local items=$(( $# / 2 ))
  local item_max
  item_max="$(ui_menu_max_item_len "$@")"
  local h w list_h
  read -r h w list_h < <(ui_dims_for_menu "$text" "$items" "$item_max")

  whiptail --title "$title" --menu "$text" "$h" "$w" "$list_h" "$@" 3>&1 1>&2 2>&3 </dev/tty
  rc=$?
  ((had_e)) && set -e
  return $rc
}

yesno() {
  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  local h w
  read -r h w < <(ui_dims_from_text "$1" 10 8 8)
  whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "$1" "$h" "$w" 3>&1 1>&2 2>&3 </dev/tty
  rc=$?
  ((had_e)) && set -e
  return $rc
}

radiolist() {
  # Usage: radiolist "<title>" "<text>" "<list_h_hint>" TAG DESC ON|OFF ...
  local title="$1" text="$2" list_h_hint="${3:-6}"
  shift 3
  [[ $# -gt 0 ]] || return 2

  local args=("$@")
  local count=$(( ${#args[@]} / 3 ))
  (( count < 1 )) && return 2

  local max=0 i tag desc combined
  for ((i=0; i<${#args[@]}; i+=3)); do
    tag="${args[i]}"; desc="${args[i+1]}"
    combined="${tag}  ${desc}"
    (( ${#combined} > max )) && max=${#combined}
  done

  ui_term_dims
  local max_w=$(( UI_TERM_COLS - UI_SAFE_MARGIN ))
  local max_h=$(( UI_TERM_LINES - UI_SAFE_MARGIN_H ))
  local soft_max=$UI_SOFT_MAX_W
  (( soft_max > max_w )) && soft_max=$max_w

  local text_longest text_lines desired_w w list_h desired_h h
  text_longest="$(printf "%s" "$text" | ui_longest_line_len)"
  text_lines="$(printf "%s" "$text" | ui_count_lines)"
  desired_w=$(( (text_longest>max?text_longest:max) + 10 ))
  w="$(ui_clamp "$desired_w" "$UI_MIN_W" "$soft_max")"

  list_h="$list_h_hint"
  (( list_h > count )) && list_h="$count"
  (( list_h < 3 )) && list_h=3
  (( list_h > 12 )) && list_h=12

  desired_h=$(( text_lines + list_h + 8 ))
  h="$(ui_clamp "$desired_h" 14 "$max_h")"

  local had_e=0 rc=0
  [[ $- == *e* ]] && had_e=1
  set +e
  whiptail --title "$title" --radiolist "$text" "$h" "$w" "$list_h" "${args[@]}" 3>&1 1>&2 2>&3 </dev/tty
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
  ui_term_dims
  local max_w=$(( UI_TERM_COLS - UI_SAFE_MARGIN ))
  local max_h=$(( UI_TERM_LINES - UI_SAFE_MARGIN_H ))
  local soft_max=$UI_SOFT_MAX_W
  (( soft_max > max_w )) && soft_max=$max_w

  local w h
  w="$(ui_clamp 90 "$UI_MIN_W" "$soft_max")"
  h="$(ui_clamp 22 12 "$max_h")"

  if ! whiptail --title "$title" --textbox "$file" "$h" "$w" </dev/tty >/dev/tty 2>/dev/tty; then
    printf "
[Unable to open textbox UI]

%s

" "$file" >/dev/tty
    cat "$file" >/dev/tty 2>/dev/tty || true
    printf "
" >/dev/tty
  fi
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
  got="$(inputbox "$prompt

Type exactly:
$phrase" "")" || return 1
  [[ "$got" == "$phrase" ]]
}
