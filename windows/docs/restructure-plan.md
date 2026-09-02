# Dotfiles Restructure Plan — unify macOS + Windows into one repo

**Goal:** fold the local Windows dotfiles (`C:\Users\mnand\dotfiles`) into the existing
GitHub repo [`Marx-A00/dotfiles`](https://github.com/Marx-A00/dotfiles) as an OS-partitioned
monorepo: single source of truth, one backup, easy cross-referencing.

**Status:** Completed historical plan. Do not execute these commands as current
instructions; use the root `README.md` for the live layout. Project agent
guidance was later consolidated into root `AGENTS.md`, with root `CLAUDE.md`
importing it for Claude Code.

---

## Why this shape

Comparing the two repos byte-for-byte, there is **essentially zero shared config** — even
Emacs is two *deliberately different* setups:

- **macOS Emacs** = full daily-driver IDE (~6,240-line `init.el`, elpaca, aux lisp, tests, literate org).
- **Windows Emacs** = lean purpose-built rig (~503 lines, package.el, "Lua + LSP for RE4R modding, agent-shell").

So this is **not a merge** — it's putting two mostly-disjoint config sets under one roof.
**We do NOT force the Emacs configs together** (reconciling 6240 vs 503 lines + elpaca vs
package.el costs days and loses the intentional Windows leanness). Keep `macos/emacs` and
`windows/emacs` separate; hand-port individual goodies as desired.

**Key insight that makes this low-risk:** both bootstraps reference configs by *relative path
from the script*. Windows uses `$repo = $PSScriptRoot` then `$repo\emacs\…` etc. So moving
`bootstrap.ps1` **and all the dirs it references** together into `windows/` keeps every path
resolving — near-zero edits to the Windows bootstrap.

---

## Target layout

```
dotfiles/
├── README.md                 # rewritten: cross-platform overview
├── .gitignore                # merged (+ /.agent-shell/)
├── shared/
│   └── CLAUDE.md             # agent guidance (OS-agnostic)
├── docs/                     # general reference notes (stays shared) — incl. this file
├── macos/
│   ├── bootstrap.sh
│   ├── .zshrc
│   ├── emacs/  yabai/  skhd/  sketchybar/  hammerspoon/  scripts/
└── windows/
    ├── bootstrap.ps1
    ├── emacs/  powershell/  glazewm/  kanata/  autohotkey/
    ├── windows-terminal/  scripts/  windows-rig-keybindings.org
```

---

## Open decisions (lock these before executing)

1. **History:** copy-in (simple, single commit) vs `git subtree` (preserves Windows log). → lean **copy-in**.
2. **`docs/`:** keep at root, or move under `shared/`? → lean **root**.
3. **`CLAUDE.md`:** `shared/` only, or also symlink it active on Windows?
4. **Merge:** PR for review, or straight to `main` (solo repo)?
5. **Mac `~/.emacs.d`:** how is it linked today? `bootstrap.sh` doesn't touch it — CONFIRM so
   `macos/bootstrap.sh` is correct.

---

## Phase 0 — Branch (on the real Mac clone, here on Windows)

```bash
cd /c/Users/mnand/mac-dotfiles-ref
git checkout main && git pull
git checkout -b restructure/monorepo
```

## Phase 1 — Move macOS files into `macos/` (history-preserving)

```bash
mkdir -p macos shared
for d in emacs yabai skhd sketchybar hammerspoon scripts; do git mv "$d" "macos/$d"; done
git mv .zshrc macos/.zshrc
git mv bootstrap.sh macos/bootstrap.sh
git mv CLAUDE.md shared/CLAUDE.md
# docs/ stays at root
git commit -m "restructure: move macOS configs under macos/, CLAUDE.md under shared/"
```
`git mv` preserves history (`git log --follow`).

## Phase 2 — Import the Windows rig into `windows/`

Copy the **working tree** from the live Windows repo (captures tracked files + untracked WIP:
glazewm, kanata, starship, the PS profile), excluding `.git` and `.agent-shell`:

```bash
mkdir -p /c/Users/mnand/mac-dotfiles-ref/windows
cd /c/Users/mnand/dotfiles
cp -r emacs powershell glazewm kanata autohotkey windows-terminal scripts \
      bootstrap.ps1 windows-rig-keybindings.org \
      /c/Users/mnand/mac-dotfiles-ref/windows/
cd /c/Users/mnand/mac-dotfiles-ref
git add windows/
git commit -m "restructure: import Windows rig under windows/"
```

> Alternative (if preserving Windows history matters): `git subtree add --prefix=windows <windows-repo> main`.

## Phase 3 — Bootstrap changes

**Windows (`windows/bootstrap.ps1`) — almost nothing changes.** `$PSScriptRoot` is now
`…/dotfiles/windows`; every `$repo\<dir>` it references moved under `windows/`, so symlink
targets and startup shortcuts still resolve. Only edit: update the `.NOTES` comment to say
`cd windows` first. No path logic touched.

**macOS (`macos/bootstrap.sh`) — small rewrite** to script-relative (files moved under `macos/`):

```bash
#!/bin/bash
DOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # …/dotfiles/macos
ln -sf "$DOTDIR/yabai/yabairc"         "$HOME/.yabairc"
ln -sf "$DOTDIR/skhd/skhdrc"          "$HOME/.skhdrc"
ln -sf "$DOTDIR/sketchybar"           "$HOME/.config/sketchybar"
ln -sf "$DOTDIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"
ln -sf "$DOTDIR/emacs/"*.plist        "$HOME/Library/LaunchAgents/"
# + ADD if not done elsewhere (CONFIRM on Mac):
# ln -sf "$DOTDIR/emacs/.emacs.d" "$HOME/.emacs.d"
# + optional shared CLAUDE.md link
```

## Phase 4 — Windows `init.el` path follow-ups

The paths anchored at `USERPROFILE\dotfiles\…` now live under `dotfiles\windows\…`.
Edit `windows/emacs/.emacs.d/init.el`:

| Binding | Before | After |
|---|---|---|
| `agent-shell-screenshot-command` | `dotfiles/powershell/agent-shell-snip.ps1` | `dotfiles/windows/powershell/agent-shell-snip.ps1` |
| `SPC e` | `dotfiles/emacs/.emacs.d/init.el` | `dotfiles/windows/emacs/.emacs.d/init.el` |
| `SPC d e` (dired dotfiles) | `dotfiles` | keep `dotfiles` (repo root) — or `dotfiles/windows` |

## Phase 5 — Merge, push

```bash
git push -u origin restructure/monorepo
# Open a PR to review the moves, or merge straight to main (solo repo).
```

## Phase 6 — Adopt on Windows

Swap the standalone repo for the unified clone at the **same canonical path**:

```powershell
Rename-Item C:\Users\mnand\dotfiles C:\Users\mnand\dotfiles.win-backup   # safety net
git clone https://github.com/Marx-A00/dotfiles.git C:\Users\mnand\dotfiles
# Re-point symlinks + startup shortcuts. Needs Dev Mode ON or run elevated (symlink-elevation gotcha):
cd C:\Users\mnand\dotfiles\windows; .\bootstrap.ps1
```
`New-Item -SymbolicLink -Force` overwrites the stale `AppData\Roaming\.emacs.d\init.el`
link to the new `…\dotfiles\windows\emacs\.emacs.d\init.el` target and recreates the
GlazeWM/kanata/AHK/daemon startup shortcuts. Verify `SPC c s` + `SPC e`, then delete the backup.

## Phase 7 — Adopt on Mac

```bash
cd ~/.dotfiles && git pull          # or re-clone
./macos/bootstrap.sh
# Confirm ~/.emacs.d + daemon still find the config.
```

---

## Risks & rollback

- **All work on a branch** → `main` safe until merge. Rollback = `git branch -D restructure/monorepo`.
- **Windows symlink re-point needs elevation/Dev Mode** — bootstrap warns + backs up real files to `.bak`.
- **Old Windows repo kept** as `dotfiles.win-backup` until verified.
- **Mac `~/.emacs.d` linking is the one unknown** — confirm before running `macos/bootstrap.sh`.

---

## Equivalence map (reference)

| Function | macOS | Windows |
|---|---|---|
| Editor | `emacs/` (full) | `emacs/` (lean) — kept separate |
| Shell | `.zshrc` | `powershell/` |
| Bootstrap | `bootstrap.sh` | `bootstrap.ps1` |
| Tiling WM | `yabai/` | `glazewm/` |
| Hotkeys | `skhd/` | `autohotkey/` |
| WM scripting | `hammerspoon/` | (in glazewm) |
| Status bar | `sketchybar/` | — |
| Kbd remap | — | `kanata/` |
| Terminal | — | `windows-terminal/` |
| Agent guidance | `CLAUDE.md` → `shared/` | (shared) |
