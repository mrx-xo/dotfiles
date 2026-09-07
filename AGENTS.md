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
- Elpaca is the package manager (v0.12, with a `repos`->`sources` compat
  symlink). Do not wipe its `builds/` directory as a cleanup step, and do not
  "fix" that symlink.

Files loaded from `agent-shell-config.el` must not hard-`require` `agent-shell`.
Elpaca has not activated packages yet when the config is loaded in batch mode,
so a hard require breaks the test suite.

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
asked for it in the current message. Not to apply a change, not to test a fix,
not as a retry. Restarting kills every agent-shell conversation, including the
current one. Live-evaluate changes instead and ask for a fresh confirmation each
time a restart seems necessary.

This prohibition includes:

- `emacs-restart.sh`, `emacs-restart-restore.sh`, and `emacs-daemon-start.sh`
- `(kill-emacs)`, `(restart-emacs)`, and `(save-buffers-kill-emacs)`
- `launchctl` operations on `com.marcosandrade.emacsdaemon`
- `kill` or `pkill` targeting Emacs

The sandbox daemon using `--socket-name=sandbox` is exempt, including
`emacs-sandbox.sh --fresh` and `--restart`. It exists to be restarted.

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

### Proposing Keybindings (IMPORTANT)

Never propose a keybinding from memory of vanilla Evil or vanilla Emacs. This
config's normal state is fully saturated: every printable ASCII key and every
`C-<letter>` is already bound, and several stock keys mean something else
(`s`/`f`/`t` and friends are evil-snipe, `C-s` is `consult-line`, `C-u` is
`evil-scroll-up`, `TAB` is not `evil-jump-forward`, `<escape>` and `C-g` are
`mr-x/escape-quit`).

Before suggesting or adding any binding, run the survey and read it. It takes
about six seconds and reports the running daemon's actual state:

```bash
~/.dotfiles/macos/scripts/evil-key-survey.sh
```

That prints the free `SPC` leader keys and a dozen gotchas a single-key lookup
will not warn you about. `--full` adds every prefix tree, the diff against
stock evil, and per-major-mode shadowing.

Nothing is checked in on purpose. A saved keymap snapshot goes stale the moment
a binding changes, and a stale one is worse than none because it gets trusted.
Regenerate, never cite a saved copy or a previous run in this conversation.

Then:

1. Put new feature bindings under the `SPC` leader — a free leader key, or a
   new key inside an existing `SPC` group. `general-override-mode` is on, so
   the leader survives every major mode.
2. Confirm the exact key is free in the live session. Probe in a scratch
   buffer, not the daemon's current buffer, or the answer depends on whatever
   mode happens to be focused (`"nil"` means free):

   ```bash
   emacsclient --eval \
     '(let ((kill-buffer-query-functions nil)) (with-current-buffer (get-buffer-create " *kb*") (fundamental-mode) (evil-local-mode 1) (evil-normal-state) (prog1 (format "%s" (key-binding (kbd "SPC k") t)) (kill-buffer))))'
   ```

3. Give any new prefix a which-key name, since `which-key-mode` is on.

## macOS Window Services

Apply configuration changes with each service's supported command:

```bash
yabai --restart-service
skhd --reload
sketchybar --reload
brew services restart borders
```

Prefer a live reload when the service supports one; yabai requires a service
restart to reread its configuration. For yabai troubleshooting, turn on
`yabai -m config debug_output on`.

## Git Branching

`main` is the branch; day-to-day work happens directly on it. Use a feature
branch only for a larger experiment.

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

## Opening URLs (agents)

Open pages with `agent-open <url>` (Brave, pinned to the `agent` yabai space,
launched without activation). Never `open -a`, never `open <url>`, never Chrome:
those steal focus and break the working layout. Prefer verifying pages headless
through the Chrome DevTools MCP; only surface a Brave window when asked.

## Task Master

When Task Master applies, read and follow `.taskmaster/CLAUDE.md`.
