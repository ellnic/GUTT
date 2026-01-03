# GUTT: Git User TUI Tool

![GUTT TUI main menu](gutt_menu.png)

**Status:** 🚧 **WIP / Alpha — Major internal refactor in progress**

GUTT wraps the *common 90%* of Git usage in a protective, terminal-based interface with strong safeguards against destructive mistakes.

> **Project note**
>
> GUTT is usable today, but it is in the middle of a deliberate, large-scale internal refactor.
> Core safety scaffolding and several major areas are complete; other areas are being rebuilt next.
> This is intentional engineering work, not churn.

---

## What it does (high level)
- Repo picker with memory (recent + last)
- Status dashboard (branch, upstream, ahead/behind, staged/untracked)
- Stage / unstage / discard
- Commit helpers (amend, reword, undo last commit)
- Branch management (guarded)
- Stash management
- Remotes & upstream helpers
- Logs & diffs
- Hygiene assistant (.gitignore suggestions)
- **Danger zone**: reset, clean, reflog, force-push (with lease), tidy-history baseline (all guarded)

---

## Refactor progress snapshot

This refactor restructures GUTT internally for clarity, safety, and long-term maintainability.
The list below is a **progress overview**, not a promise or timeline.

### Completed
- Core safety scaffolding and guard rails
- Repo discovery, selection, and memory
- Status & inspection tooling
- Branch management (list, create, switch, rename, delete, prune, upstream tracking)

### In progress
- Commit workflows and helpers
- Sync operations (fetch / pull / push variants)

### Planned
- Merge and rebase workflows (guided, guarded)
- Stash workflows (full lifecycle)
- Tags and release helpers
- Hygiene & cleanup tools
- Recovery and dangerous operations consolidation
- Settings, help, and documentation polish

---

## Safety principles
- **Refuses to run as root**
- Refuses destructive actions on dirty repos
- Dry-runs before deletes
- Typed confirmation phrases for history rewrites / force-push
- Defaults to **NO** for all destructive prompts
- Optional local safety tags before danger operations

GUTT does not try to make Git “safe”.
It makes *intent explicit* and mistakes harder.

---

## Why?
- It’s for **git**, not “GitHub” or “GitLab”
- Vendor websites and native apps often get in the way
- A terminal-first workflow deserves first-class tooling
- Why not?

---

## Requirements
- `git`
- `whiptail`
- POSIX-compatible shell environment

---

## Run
```bash
chmod +x gutt.sh
./gutt.sh
```

---

## Config & data
Stored per-user:
- `~/.config/gutt/config`
- `~/.config/gutt/repos.list`
- `~/.cache/gutt/`

---

## Disclaimer
This tool can still **destroy Git history if you tell it to**.

It is designed to slow you down, surface intent, and make consequences obvious —
not to protect you from yourself.

Use with care. Feedback welcome.
