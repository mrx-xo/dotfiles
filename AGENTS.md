# Project Agent Instructions

This is the canonical project guidance for coding agents working in this
repository. Claude Code imports it through `CLAUDE.md`; Codex reads it
directly.

## Repository Overview

This is a cross-platform dotfiles monorepo. The macOS and Windows trees are
deliberately different configurations, not two views of one merged setup.

- `macos/`: daily-driver Emacs, yabai, skhd, sketchybar, Hammerspoon, shell,
  launchd, and helper scripts.
- `windows/`: lean Emacs, GlazeWM, kanata, AutoHotkey, PowerShell, and Windows
  Terminal.
- `shared/`: cross-platform scripts and configuration.
- `docs/`: subsystem documentation and implementation notes.

See `README.md` for the full repository map and bootstrap instructions.

## No Emojis

Never use emojis in this repository or anything produced for it. This covers
UI text, code, comments, logs, commits, pull requests, documentation, and chat
responses. Use plain text status words such as `done`, `failed`, and `pending`,
or a real icon font where an interface genuinely needs an icon.

## Preserve Existing Work

The working tree may contain user changes. Preserve unrelated modifications,
avoid destructive Git commands, and stage or commit only files that belong to
the current task.

## Initial Setup

On macOS:

```bash
./macos/bootstrap.sh
```

On Windows, from the `windows/` directory:

```powershell
.\bootstrap.ps1
```

## macOS Emacs Configuration

### Source and Generated Files

- `macos/emacs/.emacs.d/emacs.org` is the primary literate configuration.
- Most blocks tangle to `init.el`.
- Agent-shell blocks tangle separately to `agent-shell-config.el`, which
  `init.el` loads.
- Standalone packages live under `macos/emacs/.emacs.d/lisp/` and are edited
  directly.
- Elpaca is the package manager. Do not wipe its `builds/` directory as a
  cleanup step.

### Tangling emacs.org

Saving `emacs.org` inside Emacs auto-tangles it. After editing it outside
Emacs, run:

```bash
~/.dotfiles/macos/scripts/tangle-emacs-org.sh
```

Do not use `emacs --batch -l org -f org-babel-tangle`, or any other `-Q` /
built-in-Org tangle. Two reasons: `-f` runs before a file is visited, and the
built-in Org (9.7) is not the Org that generates this repo's checked-in files.

**Elpaca's Org is the canon.** Since 2026-06-07 it has been 10.0-pre, which
preserves leading indentation in indented src blocks where 9.7 strips it, plus
differs on blank-line padding — about 140 lines of `init.el`. The daemon's
auto-tangle-on-save hook, `tangle-emacs-org.sh`, and the in-process tangle in
`config-test-tangled-output-in-sync` all use Elpaca's Org, so they agree with
each other and with every `init.el` this repo has committed.

If that test fails after you tangled, the fix is to re-tangle with the script,
never to re-tangle with `-Q` and never to change the test to shell out to a
`--batch -Q` subprocess. That swap was made in `d670e8b` (2026-09-02) and
silently inverted the canon: `840f6c8` had already restyled `init.el` with
built-in Org, burying ~140 lines of whitespace churn in an unrelated feature
diff. Both were reverted on 2026-09-03.

### Live Evaluation

After changing Emacs Lisp that should take effect immediately, evaluate or
load it in the running daemon with `emacsclient`.

```bash
emacsclient --eval '(elisp-expression-here)'
emacsclient --eval '(load-file "/absolute/path/to/changed-file.el")'
```

Refresh relevant buffers after loading when their rendered contents are
already open. Loading code does not necessarily rerender an existing buffer.

### Never Restart Emacs Without Permission

Never restart, kill, or reload the main Emacs daemon unless the user explicitly
asked for it in the current message. Restarting kills every agent-shell
conversation, including the current one. Live-evaluate changes instead and ask
for a fresh confirmation each time a restart seems necessary.

This prohibition includes:

- `emacs-restart.sh`, `emacs-restart-restore.sh`, and `emacs-daemon-start.sh`
- `(kill-emacs)`, `(restart-emacs)`, and `(save-buffers-kill-emacs)`
- `launchctl` operations on `com.marcosandrade.emacsdaemon`
- `kill` or `pkill` targeting Emacs

The sandbox daemon using `--socket-name=sandbox` is exempt.

### Sandbox Emacs

The sandbox at `~/.emacs-sandbox` is isolated from the main daemon. Launch it
with `Cmd+Shift+S` or:

```bash
~/.dotfiles/macos/scripts/emacs-sandbox.sh
```

Evaluate Lisp in it with:

```bash
emacsclient --socket-name=sandbox --eval '(elisp-expression-here)'
```

Edit the sandbox's `init.el` directly for experiments. Promote successful
changes to the real `emacs.org` or standalone Lisp file afterward.

### Testing

The main ERT smoke suite is
`macos/emacs/.emacs.d/tests/config-tests.el`. After modifying `emacs.org` or
`init.el`, run it and confirm the tangled output remains synchronized.

```bash
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch \
  -l ~/.emacs.d/init.el \
  -l ~/.emacs.d/tests/config-tests.el \
  -f ert-run-tests-batch-and-exit
```

Standalone packages may have focused ERT files under the same `tests/`
directory; run those in addition to the smoke suite.

### Package Management

Use Elpaca through Emacs:

```text
M-x elpaca-update-all
M-x elpaca-rebuild
M-x elpaca-log
```

## macOS Window Services

Apply configuration changes with each service's supported command:

```bash
yabai --restart-service
skhd --reload
sketchybar --reload
```

Prefer a live reload when the service supports one; yabai requires a service
restart to reread its configuration.

## Windows Configuration

Windows Emacs uses `package.el` with MELPA. Edit
`windows/emacs/.emacs.d/init.el` directly; it is not a literate configuration.
Windows bootstrap and subsystem details live in `windows/README.md` and
`windows/bootstrap.ps1`.

## Design Docs and Vocabulary

Rig-level specs live in `macos/docs/superpowers/specs/`, plans and handoffs
in `macos/docs/superpowers/plans/`, subsystem PRDs in `docs/`. An optional
house template for the spec shape is `docs/templates/prd.md` (reference it in
a chat as `@docs/templates/prd.md`). Vocabulary for the whole rig is
`~/atlas/glossary.md`; add a line there when a feature coins a term.

## Explanation Style

When explaining code, include a concrete snippet when it improves clarity and
identify its full file path in a comment. Keep prose direct and avoid markdown
tables in narrow agent-shell windows; prefer short lists.

## Task Master

When Task Master applies, read and follow `.taskmaster/CLAUDE.md`.
