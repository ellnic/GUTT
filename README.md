# GUTT: Git User TUI Tool

![GUTT TUI main menu](gutt_menu.png)

**Status:** 🚧 **WIP / Alpha**

GUTT wraps the common 90% of Git usage in a protective, terminal based interface with strong safeguards against destructive mistakes.

---

## What it does

- Repository picker with memory (recent and last used)
- Status dashboard (branch, upstream, ahead or behind, staged and untracked)
- Plain English workflows for common Git tasks
- Beginner and Advanced modes sharing the same underlying logic
- Guarded save, undo, tidy, and recovery helpers
- Optional safety checkpoints before risky operations
- Centralised plan screens that explain impact before changes happen

---

## Modes

### Beginner Mode
Beginner mode avoids Git specific terminology and presents actions in plain English.  
Examples include saving work, undoing a mistake, sending work online, and cleaning up history.

Beginner mode rules:
- No Git jargon in menus or prompts
- All risky actions require an explanation screen first
- Default answer is always No
- Typed confirmation is required for irreversible actions

### Advanced Mode
Advanced mode exposes more traditional Git wording and workflows but still routes all actions through the same safety layers.

Advanced mode never bypasses safeguards.

---

## Safety principles

- Refuses to run as root
- Defaults to No for all risky confirmations
- Cancel or Esc never exits the entire application
- Typed confirmation for history rewrites and force updates
- Optional local checkpoints before destructive actions
- Clear plan screens before AMBER and RED risk actions

GUTT does not try to make Git safe. It makes intent explicit and mistakes harder.  
You can still damage a repository if you ignore warnings.

---

## Internal structure (7 file layout)

GUTT is structured into seven clearly defined files to reduce risk and keep responsibilities isolated.

1. `gutt`  
   Loader and router. Sources files in a fixed order and shows the top level menu.

2. `lib_core.sh`  
   Core helpers, logging, repo detection, and state gathering. No UI logic.

3. `lib_ui.sh`  
   All dialog and whiptail wrappers. Handles Cancel and default No behaviour.

4. `lib_git.sh`  
   Pure Git primitives. No UI. Returns exit codes and output only.

5. `lib_actions.sh`  
   Shared action layer. Maps actions to risk levels and builds plan data.

6. `ui_menus.sh`  
   Beginner and Advanced menus. Presentation only. Calls action functions.

7. `tools_path.sh`  
   PATH install, remove, and status logic using a safety focused wrapper.

No file sources another file directly.  
All sourcing is done once by `gutt` in a fixed order.

---

## Requirements

- `git`
- `whiptail`
- POSIX compatible shell environment

---

## Run

```bash
chmod +x gutt
./gutt
```

---

## Config and data

Stored per user:

- `~/.config/gutt/config`
- `~/.config/gutt/repos.list`
- `~/.cache/gutt/`

---

## Project status and disclaimer ⚠️

**GUTT IS CURRENTLY IN ACTIVE DEVELOPMENT AND SHOULD BE CONSIDERED ALPHA SOFTWARE.  IT MAY CONTAIN BUGS THAT COULD LEAD TO REPOSITORY DAMAGE OR DATA LOSS. YOU SHOULD REVIEW THE CODE BEFORE USE. THIS SOFTWARE IS PROVIDED WITHOUT WARRANTY AND IS USED AT YOUR OWN RISK.**

---

## Licence 📄

GUTT is released under the GNU General Public License v3.0 or later.
