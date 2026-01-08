#!/usr/bin/env bash
# ui_menus.sh - Beginner + Advanced menus and wording (UI layer; calls action_*)

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

vnext_recovery_danger_menu() {
  local repo="$1"

  # Phase 9.1 scaffold: Recovery helpers live here, with the existing Danger Zone kept intact.
  # No behaviour changes unless the user explicitly chooses a new Recovery placeholder item.
  while true; do
    local choice
    choice="$(menu "Recovery & Dangerous" "Recovery helpers

Choose an action" \
      "KGTAGS" "Show saved safety bookmarks" \
      "CHECK"  "Show recovery checklist" \
      "GOKG"   "Go back to a saved safety bookmark (guided)" \
      "BRKG"   "Recover by starting a new work line (shortcut)" \
      "EMERG"  "Emergency: recent checkpoints + safe undo tips" \
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
      "SOON" "Coming soon / notes" \
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
      SOON) vnext_coming_soon ;;
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

beginner_get_info() {
  local repo="$1"
  show_dashboard "$repo"
}

beginner_see_what_changed() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Beginner: See what changed\n\nProject folder:\n$repo\n\nChoose what to view (read-only)" \
      "QSUM" "Quick summary (what changed + size summary)" \
      "DIFF" "Full details (everything that changed)" \
      "UPST" "Compare with online copy (if linked)" \
      "LOGS" "History and comparisons (advanced view, read-only)" \
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


beginner_mark_checkpoint() {
  local repo="$1"
  local ts default_label label note msg tmp workline snap

  ts="$(date +%Y%m%d-%H%M)"
  default_label="gutt/known-good-$ts"

  workline="$(cd "$repo" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  snap="$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo "?")"

  label="$(inputbox "Save safety bookmark

Name for this bookmark:" "$default_label")" || return 0
  label="${label## }"; label="${label%% }"

  if ! validate_tag_name "$label"; then
    msgbox "Invalid name:

$label"
    return 0
  fi

  note="$(inputbox "Optional note (leave blank for none):" "")" || return 0
  note="${note## }"; note="${note%% }"

  msg="Safety bookmark saved by GUTT"$'
'"Work line: $workline"$'
'"Snapshot:  $snap"
  if [[ -n "$note" ]]; then
    msg="$msg"$'

'"Note: $note"
  fi

  tmp="$(mktemp_gutt)"
  (cd "$repo" && git tag -a "$label" -m "$msg") >"$tmp" 2>&1 || true
  if git_tag_exists "$repo" "$label"; then
    {
      echo "Saved safety bookmark:"
      echo
      echo "  Bookmark : $label"
      echo "  Work line: $workline"
      echo "  Snapshot : $snap"
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
    if whiptail --title "$APP_NAME $VERSION" --yesno --defaultno       "Upload this bookmark to the online copy now?

Bookmark: $label" 12 78 3>&1 1>&2 2>&3; then
      run_git_capture "$repo" git push origin "$label"
    fi
  else
    msgbox "No online copy is set up.

This bookmark is saved locally only."
  fi
}

beginner_upload_now() {
  local repo="$1"
  local workline upstream remote cmd

  workline="$(git_current_branch "$repo")"
  if [[ -z "$workline" ]]; then
    msgbox "Not a project folder I can work with (or cannot read the current work line)."
    return 1
  fi
  if [[ "$workline" == "HEAD" ]]; then
    msgbox "You're not on a named work line right now.

Switch to a work line first, then try again."
    return 1
  fi

  upstream="$(git_upstream "$repo")"

  if [[ -n "$upstream" ]]; then
    if ! whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "Upload your work now?

Work line: $workline

An online destination is already linked for this work line.

Nothing is uploaded unless you choose YES." 14 78 3>&1 1>&2 2>&3; then
      msgbox "Cancelled."
      return 0
    fi
    cmd=(git push)
  else
    if (cd "$repo" && git remote 2>/dev/null | grep -qx "origin"); then
      remote="origin"
    else
      remote="$(cd "$repo" && git remote 2>/dev/null | head -n1 || true)"
    fi

    if [[ -z "$remote" ]]; then
      msgbox "No online copy is set up.

Set up an online copy first, then try again."
      return 1
    fi

    if ! whiptail --title "$APP_NAME $VERSION" --defaultno --yesno "This work line is not linked to an online target yet.

Work line: $workline

We can link this work line to the default online destination, then upload.

Nothing is uploaded unless you choose YES." 18 78 3>&1 1>&2 2>&3; then
      msgbox "Cancelled."
      return 0
    fi

    cmd=(git push -u "$remote" "$workline")
  fi

  if [[ "$(cfg_get auto_fetch_before_push 1)" == "1" ]]; then
    local tmpf rc
    tmpf="$(mktemp_gutt)"
    (cd "$repo" && git fetch --all --prune) >"$tmpf" 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
      textbox "$tmpf"
      rm -f "$tmpf"
      msgbox "Update check failed. Upload aborted."
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
    msgbox "Upload completed successfully."
  else
    msgbox "Upload failed.

Review the output for details."
  fi
  return $rc
}


beginner_ignore_suggest() {
  local repo="$1"
  local suggestions=()

  [[ -d "$repo/node_modules" ]] && suggestions+=("node_modules/")
  [[ -d "$repo/.venv" ]] && suggestions+=(".venv/")
  [[ -d "$repo/venv" ]] && suggestions+=("venv/")
  [[ -d "$repo/__pycache__" ]] && suggestions+=("__pycache__/")
  [[ -d "$repo/.idea" ]] && suggestions+=(".idea/")
  [[ -d "$repo/.vscode" ]] && suggestions+=(".vscode/")

  if [[ "${#suggestions[@]}" -eq 0 ]]; then
    msgbox "No obvious ignore suggestions found in a quick scan."
    return 0
  fi

  local tmp; tmp="$(mktemp_gutt)"
  cat >"$tmp" <<EOF
Suggested ignore entries:

$(printf '%s\n' "${suggestions[@]}")

Add to your project's ignore list?
EOF
  textbox "$tmp"
  rm -f "$tmp"

  if yesno "Add these entries to the ignore list now?

(Will avoid duplicates.)" ; then
    touch "$repo/.gitignore"
    for s in "${suggestions[@]}"; do
      grep -qxF "$s" "$repo/.gitignore" 2>/dev/null || printf '%s\n' "$s" >> "$repo/.gitignore"
    done
    msgbox "Ignore list updated."
  fi
}

beginner_hygiene_scan() {
  local repo="$1"
  local tmp; tmp="$(mktemp_gutt)"
  local changed_count staged_count untracked_count det_head link_state

  changed_count="$(cd "$repo" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  staged_count="$(cd "$repo" && git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
  untracked_count="$(cd "$repo" && git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"

  det_head="no"; git_is_detached "$repo" && det_head="YES"
  link_state="not linked"; [[ -n "$(git_upstream "$repo")" ]] && link_state="linked"

  cat >"$tmp" <<EOF
Project tidy report

Detached state:   $det_head
Online link:      $link_state

Changed files:    $changed_count
Prepared to save: $staged_count
New/untracked:    $untracked_count

Ignore list file: $( [[ -f "$repo/.gitignore" ]] && echo "present" || echo "missing" )

Notes:
- GUTT refuses destructive actions when the project has local changes.
- Keep secrets out of projects.
EOF
  textbox "$tmp"
  rm -f "$tmp"
}

beginner_save_checkpoint() {
  local repo="$1"
  msgbox "Beginner: Save a checkpoint" "We'll save a safety bookmark for the exact state you're on right now.

This does not change your files.

You can also choose to upload the bookmark to your online copy (optional).

All confirmations default to NO."
  beginner_mark_checkpoint "$repo"
}

beginner_upload_changes() {
  local repo="$1"
  msgbox "Beginner: Upload my changes" "We'll show you what you're about to upload, then ask for confirmation.

Nothing is uploaded unless you choose YES.

All confirmations default to NO."
  beginner_upload_now "$repo"
}

beginner_download_updates() {
  local repo="$1"
  msgbox "Beginner: Download updates" "We'll download updates from your online copy now.

This may change files in your project folder, and the full output will be shown."
  action_pull "$repo"
}

beginner_start_new_work() {
  local repo="$1"
  msgbox "Beginner: Start a new piece of work" "We'll help you start a new work line so you can work safely without touching your main line.

Nothing is changed unless you confirm.

All confirmations default to NO."
  vnext_create_feature_branch "$repo"
}

beginner_publish_cleanly_to_main() {
  local repo="$1"
  msgbox "Beginner: Publish cleanly to main" "This is a safe, guided way to put your work onto your main line (usually by squashing it into one tidy step).

Nothing is changed unless you confirm.

All confirmations default to NO."
  vnext_squash_merge_into_main "$repo"
}

beginner_tidy_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Beginner: Tidy up files safely\n\nProject folder:\n$repo\n\nSafe helpers only.\n\nNothing destructive is done from here." \
      "SCAN" "Show hygiene report" \
      "PREV" "Preview what cleanup would remove (dry-run)" \
      "IGN"  "Suggest ignore rules (guarded)" \
      "BACK" "Back")" || return 0

    case "$choice" in
      SCAN)
        beginner_hygiene_scan "$repo"
        ;;
      PREV)
        msgbox "Dry-run only" "Next, we'll show a DRY-RUN preview.\n\nThis does not delete anything."
        run_git_capture "$repo" git clean -ndx
        ;;
      IGN)
        # This routes to existing helper. It may offer to append; user must confirm (default NO).
        beginner_ignore_suggest "$repo"
        ;;
      BACK) return 0 ;;
    esac
  done
}

beginner_safety_menu() {
  local repo="$1"
  while true; do
    local choice
    choice="$(menu "$APP_NAME $VERSION" "Beginner: Get back to safety\n\nProject folder:\n$repo\n\nRecovery helpers (guarded).\n\nNo 'Danger Zone' here." \
      "CHECK" "Show recovery checklist" \
      "KGTAGS" "Show saved safety bookmarks" \
      "GOKG"   "Go back to a saved safety bookmark (guided)" \
      "BRKG"   "Recover by starting a new work line (shortcut)" \
      "EMERG"  "Emergency: recent checkpoints + safe undo tips" \
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
    choice="$(menu "$APP_NAME $VERSION" "Beginner mode (Guided)\n\nProject folder:\n$repo\n\nChoose an action" \
      "INFO" "Get info on the project folder" \
      "CHNG" "See what changed" \
      "SAVE" "Save a checkpoint" \
      "UPLD" "Upload my changes to the online copy" \
      "DOWN" "Download updates from the online copy" \
      "WORK" "Start a new piece of work" \
      "PUBL" "Publish cleanly into the main line" \
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
