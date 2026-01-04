# GUTT: Git User TUI Tool

![GUTT TUI main menu](gutt_menu.png)

**Status:** 🚧 **WIP / Alpha**

GUTT wraps the common 90% of Git usage in a protective, terminal-based interface with strong safeguards against destructive mistakes.

---

## What it does
- Repository picker with memory (recent and last used)
- Status dashboard (branch, upstream, ahead or behind, staged and untracked)
- Stage, unstage, and discard helpers
- Commit helpers (amend, reword, undo last commit)
- Branch management (guarded)
- Remote and upstream helpers
- Logs and diffs
- Hygiene assistant (.gitignore suggestions)
- **Danger zone**: reset, clean, reflog, force-push with lease, tidy-history baseline (all guarded)

---

## Current development status

GUTT is undergoing a structured internal refactor focused on safety, clarity, and long-term maintainability.

### Stable and available
- Core safety scaffolding and guard rails
- Repository discovery, selection, and memory
- Status and inspection tooling
- Branch management (list, create, switch, rename, delete, prune, upstream tracking)
- Fetch, pull, and push operations with guarded variants

### Actively expanding
- Commit workflows and helpers

### Upcoming
- Guided merge and rebase workflows
- Full stash lifecycle support
- Tag and release helpers
- Hygiene and cleanup tools
- Recovery and high-risk operation helpers
- Settings, help, and documentation polish

---

## Safety principles
- **Refuses to run as root**
- Refuses destructive actions on dirty repositories
- Dry-runs before deletes
- Typed confirmation phrases for history rewrites and force-push
- Defaults to **NO** for all destructive prompts
- Optional local safety tags before dangerous operations

GUTT does not try to make Git safe. It makes intent explicit and mistakes harder. *You can still destroy your repos if you do not know what you are doing.*

---

## Why?
- It is for **Git**, not hosting platforms
- Web UIs and vendor tooling often get in the way
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

## Config and data
Stored per user:
- `~/.config/gutt/config`
- `~/.config/gutt/repos.list`
- `~/.cache/gutt/`

---

## Project Status and Disclaimer ⚠️

**GUTT IS CURRENTLY IN ACTIVE DEVELOPMENT AND SHOULD BE CONSIDERED ALPHA SOFTWARE. GUTT MAY CONTAIN BUGS THAT COULD LEAD TO REPOSITORY DAMAGE OR DATA LOSS. YOU SHOULD REVIEW THE CODE YOURSELF BEFORE RUNNING IT. THIS TOOL IS PROVIDED WITH ABSOLUTELY NO WARRANTY, EXPRESS OR IMPLIED. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY ARISING FROM THE USE OF THIS SOFTWARE. YOU USE THIS TOOL ENTIRELY AT YOUR OWN RISK. THE SCRIPT IS PROVIDED "AS IS" AND IN GOOD FAITH WITH THE INTENT OF ASSISTING SAFE, INTENTIONAL GIT USAGE.**

---

## Transparency note 🤖

Some parts of this project are developed with the assistance of AI tools.  
All logic, safety decisions, and final changes are reviewed, tested, and curated by the project author.  
AI assistance is used as a productivity aid, not as an autonomous decision-maker.

---

## Licence 📄

GUTT is released under the GNU General Public License v3.0 or later.
