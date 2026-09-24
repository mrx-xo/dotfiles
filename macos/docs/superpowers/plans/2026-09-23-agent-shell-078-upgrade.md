# agent-shell 0.63.2 to 0.78.2 Upgrade Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the daily-driver Emacs (POLLUX, `~/.dotfiles`) from agent-shell 0.63.2 to 0.78.2 with chat mode off and the persistent prompt on, without breaking any SYZYGY feature (phone turns, resync lock, live mode, refs, slash local commands).

**Architecture:** agent-shell is an Elpaca package built from `elpaca/sources/agent-shell`, configured in `macos/emacs/.emacs.d/emacs.org` (agent-shell blocks tangle to `agent-shell-config.el`). SYZYGY lives in `macos/emacs/.emacs.d/lisp/syzygy/` and hooks agent-shell through `advice-add`. The phone path is `acp-multiplex` (Go, `~/src/acp-multiplex`, branch `syzygy`) between agent-shell and `claude-agent-acp`.

**Tech Stack:** Emacs 30 (emacs-plus@30), Elpaca 0.12, ERT, Go 1.25, zsh.

**Already decided (do not re-litigate):**

- Chat mode OFF. It is badges only; verified 2026-09-23 that it does not conflict with SYZYGY, Marcos simply does not want the look.
- Persistent prompt ON (upstream default). Marcos wants it.
- Steering stays available via `M-RET` / `agent-shell-prompt-steer`.

**Already verified in the MrX2 sandbox (agent-shell 0.78.2, commit `4cbcd12`):**

- A faked phone prompt through acp-multiplex renders above the persistent prompt with no "No live prompt to render above" error.
- A desktop steer interrupts Claude mid-turn, and acp-multiplex `fdfb2cf` forwards it to secondaries as a `[steer] ...` user chunk.
- Every advised function keeps its arglist; every subscribed event name still fires; no config symbol was removed upstream.

Target commits (all fetched in `~/.emacs.d/elpaca/sources/<pkg>` as `origin/main`): agent-shell `4cbcd12` (0.78.2), shell-maker `f448a74`, acp `242cef6`.

## Global Constraints

- Never restart, kill or reload the main Emacs daemon. Task 7 ends by asking Marcos for the restart; it does not perform it.
- No emojis anywhere, including commit messages and test names.
- The working tree already holds unrelated modified files (`emacs.org`, `init.el`, `pr-workflow.el`, `ghostty/config`, sketchybar, `macos/tmux/`). Stage only the files each task names.
- Edit `emacs.org`, never `init.el` or `agent-shell-config.el` directly. Tangle with `~/.dotfiles/macos/scripts/tangle-emacs-org.sh`, never `emacs --batch -Q`.
- Files loaded from `agent-shell-config.el` and `lisp/syzygy/` must not hard-`require` `agent-shell`. Use `declare-function` and `with-eval-after-load`.
- Do not touch `~/roaming`, org-roam, or `~/ATLAS.md`.
- Sandbox work happens on MrX2 (`ssh -n mrx2`, socket name `sandbox`). Launch or restart the sandbox through MrX2's main daemon, not from the ssh shell, or Claude reports "Authentication required" (Keychain is GUI-session only):

  ```bash
  ssh -n mrx2 '/opt/homebrew/opt/emacs-plus@30/bin/emacsclient --eval "(start-process-shell-command \"sandbox-restart\" nil \"zsh -lc ~/.dotfiles/macos/scripts/emacs-sandbox.sh\\ --restart\")"'
  ```

- Every headless call over ssh gets `timeout` and `-n`.

## Review Focus

- Mid-turn submits in 0.78 do not pass through `shell-maker-submit`: `agent-shell-submit` calls `agent-shell--busy-submit` directly when `(shell-maker-busy)` is non-nil. Any guard that only advises `shell-maker-submit` is silently skipped for queued and steered prompts.
- Under the persistent prompt, upstream signals an error whenever it must render above a prompt that is not live. SYZYGY's live mode re-pins the prompt mark after each phone-turn insert; if that error ever appears in `*Messages*`, stop and report rather than patching upstream.
- `syzygy-live--guard-submit` currently refuses submits for two seconds after any notification that arrives with no active request, which now includes upstream's own idle-time notifications. It must only react to phone turns.

## Task 1: Turn chat mode off in emacs.org

**Files:**
- Modify: `macos/emacs/.emacs.d/emacs.org` (the `use-package agent-shell` `:config` block, near the `agent-shell-anthropic-claude-acp-command` setq around line 10446)

- [ ] Add, with a two-line comment saying chat mode is a cosmetic relabel Marcos declined on 2026-09-23 and that the persistent prompt stays on:

  ```elisp
  ;; /Users/marcosandrade/.dotfiles/macos/emacs/.emacs.d/emacs.org
  (setq agent-shell-chat-mode-enabled nil)
  ```

- [ ] Tangle: `~/.dotfiles/macos/scripts/tangle-emacs-org.sh`
- [ ] Confirm the line landed in the tangled file: `grep -n agent-shell-chat-mode-enabled ~/.emacs.d/agent-shell-config.el ~/.emacs.d/init.el`
- [ ] Run the smoke suite (expected: all pass, including `config-test-tangled-output-in-sync`):

  ```bash
  /opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -l ~/.emacs.d/init.el -l ~/.emacs.d/tests/config-tests.el -f ert-run-tests-batch-and-exit
  ```

- [ ] Commit only `emacs.org` and the tangled file(s) this change touched: `emacs(agent-shell): chat mode off, persistent prompt stays on`

## Task 2: Guard mid-turn submits for the resync lock and live mode

**Files:**
- Modify: `macos/emacs/.emacs.d/lisp/syzygy/syzygy-resync.el` (`syzygy-resync--guard-submit`, around line 123)
- Modify: `macos/emacs/.emacs.d/lisp/syzygy/syzygy-live.el` (`syzygy-live--guard-submit`, around line 288)
- Create: `macos/emacs/.emacs.d/lisp/syzygy/syzygy-busy-submit-test.el`

Upstream signature to advise, from `agent-shell-prompt-queue.el`:

```elisp
;; upstream, do not edit
(cl-defun agent-shell--busy-submit (&key prompt override) ...)
```

- [ ] Write the failing ERT tests first. Each test defines a stub `agent-shell--busy-submit` (a `cl-defun` with the same keys that records its call) inside a temp buffer, sets the guard's condition, calls the advised function and asserts: locked buffer signals `user-error` and the stub is not called; unlocked buffer calls the stub with the same `:prompt`. Mirror the existing test style in `syzygy-launch-test.el`.
- [ ] Run them and confirm they fail:

  ```bash
  /opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -Q -L ~/.emacs.d/lisp/syzygy -l syzygy-busy-submit-test.el -f ert-run-tests-batch-and-exit
  ```

- [ ] In `syzygy-resync.el`, add `(advice-add 'agent-shell--busy-submit :around #'syzygy-resync--guard-submit)` next to the existing `shell-maker-submit` advice. The guard already takes `(orig &rest args)`, so it works for both.
- [ ] In `syzygy-live.el`, do the same for `syzygy-live--guard-submit`.
- [ ] Do NOT advise `agent-shell--busy-submit` for `agent-shell-refs--around-submit` or `mr-x/agent-shell-intercept-local-commands`; they read the prompt region from the buffer, which is already cleared by the time the router runs. Leave a one-line comment in each guard noting that.
- [ ] Tests pass. Load both files live in the daemon with `emacsclient --eval '(load-file ...)'` and confirm no error.
- [ ] Commit: `syzygy: guard queued and steered prompts too`

## Task 3: Make the live-mode submit guard react only to phone turns

**Files:**
- Modify: `macos/emacs/.emacs.d/lisp/syzygy/syzygy-live.el` (`syzygy-live--on-notification`, the `(setq syzygy-live--last-rx ...)` at line 248)
- Modify: `macos/emacs/.emacs.d/lisp/syzygy/syzygy-busy-submit-test.el`

- [ ] Add a failing test: a notification of kind `session_info_update` with no active requests must leave `syzygy-live--last-rx` nil; an out-of-turn `user_message_chunk` (see `syzygy-live--out-of-turn-user-chunk-p`) or any chunk while `syzygy-live--remote-turn-active` is non-nil must set it.
- [ ] Change the `setq` so it runs only when `(or (syzygy-live--out-of-turn-user-chunk-p state notification) syzygy-live--remote-turn-active)`.
- [ ] Tests pass. Load the file live.
- [ ] Commit: `syzygy(live): only phone chunks arm the submit guard`

## Task 4: Verify Tasks 1 to 3 in the MrX2 sandbox

**Files:** none edited. Uses `~/src/acp-multiplex/scripts/fake-phone.py` and `fake-phone-listen.py` (README section "Faking a phone frontend").

- [ ] On MrX2: `git pull` in `~/.dotfiles`, re-tangle, then relaunch the sandbox through the main daemon (command in Global Constraints). Confirm `(lm-version (locate-library "agent-shell.el"))` is `0.78.2` and `agent-shell-chat-mode-enabled` is nil.
- [ ] Start a multiplexed Claude shell in the sandbox from `~/.dotfiles` (the config routes through `acp-multiplex` when it is on `exec-path`; MrX2 has it at `~/.local/bin/acp-multiplex`, add that dir to `exec-path` in the sandbox if `executable-find` returns nil).
- [ ] Find the socket: `ls "$(emacsclient --socket-name=sandbox --eval '(getenv "TMPDIR")' | tr -d '"')acp-multiplex/"`.
- [ ] Phone turn: run `fake-phone.py` with a one-line prompt. Expect the `DAEMON` block in the buffer and an empty error filter on `*Messages*` for `No live prompt|[Ee]rror|give it a beat`.
- [ ] Lock: set `syzygy-resync--behind` to 1 in the buffer, start a long turn, submit mid-turn with `agent-shell-submit`. Expect the `user-error` about phone turns behind and no queued prompt (`agent-shell--prompt-queue` stays nil). Reset the variable.
- [ ] Steer: with `fake-phone-listen.py` running, start a long turn and call `agent-shell-prompt-steer` after four seconds. Expect `[steer] ...` in the listener log and an interrupted reply in the buffer.
- [ ] Report each result verbatim in the handoff.

## Task 5: Pin and push acp-multiplex

**Files:**
- Modify: `macos/syzygy/build-acp-tools.sh` (`ACP_MULTIPLEX_COMMIT`, line 21, and the comment block above it)

- [ ] In `~/src/acp-multiplex`, confirm `git log --oneline -3` shows `9577ffd` and `fdfb2cf` on `syzygy`, tests pass with `go test ./...`, then `git push fork syzygy`.
- [ ] Set `ACP_MULTIPLEX_COMMIT` to the full hash of `9577ffd` and append two comment lines: `fdfb2cf` (synthesize `[steer]` user chunk for `_session/steering`) and `9577ffd` (fake-phone scripts and README).
- [ ] Run `~/.dotfiles/macos/syzygy/build-acp-tools.sh` on POLLUX and confirm `~/.local/bin/acp-multiplex` was rebuilt (mtime now). Running multiplex processes keep the old binary; that is expected.
- [ ] Commit: `syzygy: pin acp-multiplex 9577ffd (steer synth, fake-phone scripts)`

## Task 6: Update the POLLUX Elpaca sources to the tested commits

**Files:** none in the repo. Elpaca state under `~/.emacs.d/elpaca/`.

- [ ] For each of `agent-shell`, `shell-maker`, `acp` in `~/.emacs.d/elpaca/sources/`: `git fetch -q origin && git checkout -q <target commit>` (commits listed at the top). Do not use `origin/main` blindly; the sandbox verified those exact commits.
- [ ] Rebuild from the running daemon, then kick the queue, since `elpaca-rebuild` alone does not run in a daemon:

  ```bash
  emacsclient --eval '(progn (dolist (p (list (quote shell-maker) (quote acp) (quote agent-shell))) (elpaca-rebuild p)) (elpaca-process-queues) :ok)'
  ```

- [ ] Wait until `find ~/.emacs.d/elpaca/builds/agent-shell -name "*.elc" -mmin -5 | wc -l` is at least 40, and `ls ~/.emacs.d/elpaca/builds/agent-shell/ | grep -c antigravity` is 2.
- [ ] Do not `load-library` the new build into the running daemon. Existing agent-shell buffers, including the one driving this plan, are on 0.63 code and mixing versions in one process is not supported.

## Task 7: Hand off for the daemon restart

- [ ] Write the handoff in `macos/docs/superpowers/plans/2026-09-23-agent-shell-078-upgrade-handoff.md`: what was committed (hashes), sandbox results from Task 4, the three Elpaca source commits now checked out, and the rollback below.
- [ ] End with exactly this ask, and stop: `Next: restart the main Emacs daemon to load agent-shell 0.78.2. I will not do it without your go-ahead in this message.`

## Rollback

- Elpaca sources: `git checkout 3ed71cc` (agent-shell), then the previous shell-maker and acp commits from `git reflog` in each source dir, rebuild as in Task 6, restart on Marcos's go.
- Persistent prompt misbehaving after promotion: `(setopt agent-shell-persistent-prompt-enabled nil)` in the daemon restores 0.63 prompt behaviour without a restart.
- acp-multiplex: `build-acp-tools.sh` with `ACP_MULTIPLEX_COMMIT` back to `39e79c8`.
