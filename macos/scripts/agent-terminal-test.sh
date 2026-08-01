#!/bin/bash
# agent-terminal-test.sh [--live] [--emacs] — smoke suite for the Agent
# Terminal stack (docs/agent-terminal.md). Run before/after touching any
# moving part; add a check whenever a bug teaches us something new.
#
#   default : offline checks, incl. headless UX/rendering ERT (no tokens, ~30s)
#   --live  : adds one real headless `claude -p` run through tmux interception
#   --emacs : ALSO runs the UX suite inside your RUNNING Emacs — windows
#             visibly pop and close (observer toggle, vterm attach). The demo.
#
# Exits nonzero if anything fails. Saves/restores your tmux-intercept flag.

set -u

SCRIPTS="$HOME/.dotfiles/macos/scripts"
EMACSD="$HOME/.dotfiles/macos/emacs/.emacs.d"
LISP="$EMACSD/lisp"
FLAG="$HOME/.claude/agent-tmux-enabled"
EMACS_BATCH="/opt/homebrew/opt/emacs-plus@30/bin/emacs"
LIVE=0; INEMACS=0
for arg in "$@"; do
  case "$arg" in
    --live) LIVE=1 ;;
    --emacs) INEMACS=1 ;;
  esac
done

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# preserve user's flag state
HAD_FLAG=0; [ -f "$FLAG" ] && HAD_FLAG=1
restore() {
  if [ "$HAD_FLAG" = 1 ]; then touch "$FLAG"; else rm -f "$FLAG"; fi
}
trap restore EXIT
rm -f "$FLAG"   # offline tests assume interception OFF

b64() { printf '%s' "$1" | base64; }

# ── Layer 1: observer plumbing ─────────────────────────────────────────────
section "Layer 1 — observer (hook script → emacsclient → buffer)"

if emacsclient --eval "t" >/dev/null 2>&1; then
  MARK="at-test-$$-$RANDOM"
  printf '{"session_id":"at-test-session","cwd":"/tmp","tool_input":{"command":"echo %s","description":"smoke probe"}}' "$MARK" \
    | "$SCRIPTS/agent-terminal-hook.sh" pre
  printf '{"session_id":"at-test-session","cwd":"/tmp","tool_response":{"stdout":"%s-output","stderr":"","interrupted":false}}' "$MARK" \
    | "$SCRIPTS/agent-terminal-hook.sh" post
  sleep 1  # delivery is backgrounded
  if [ "$(emacsclient --eval "(with-current-buffer (agent-terminal--buffer) (and (string-match-p \"$MARK\" (buffer-string)) t))" 2>/dev/null)" = "t" ]; then
    ok "pre hook payload landed in *agent-terminal*"
  else
    bad "pre hook payload landed in *agent-terminal*"
  fi
  if [ "$(emacsclient --eval "(with-current-buffer (agent-terminal--buffer) (and (string-match-p \"$MARK-output\" (buffer-string)) t))" 2>/dev/null)" = "t" ]; then
    ok "post hook output landed in *agent-terminal*"
  else
    bad "post hook output landed in *agent-terminal*"
  fi
else
  printf '  SKIP: no Emacs daemon — observer delivery untested\n'
fi

# hook must never fail even with garbage input
if printf 'not json at all' | "$SCRIPTS/agent-terminal-hook.sh" pre; then
  ok "hook script survives garbage input (exit 0)"
else
  bad "hook script survives garbage input" "exited $?"
fi

# ── Layer 2: wrapper contract ──────────────────────────────────────────────
section "Layer 2 — agent-term-run.sh wrapper"
RUN="$SCRIPTS/agent-term-run.sh"

out="$("$RUN" "$(b64 'echo wrapper-basic-ok')")"; rc=$?
[ "$out" = "wrapper-basic-ok" ] && [ $rc -eq 0 ] && ok "basic output + rc 0" || bad "basic output + rc 0" "out=$out rc=$rc"

"$RUN" "$(b64 'sh -c "exit 42"')" >/dev/null; rc=$?
[ $rc -eq 42 ] && ok "exit code propagates (42)" || bad "exit code propagates (42)" "rc=$rc"

out="$("$RUN" "$(b64 'cat <<EOF
line-one
line-two
EOF')")"
[ "$out" = "line-one
line-two" ] && ok "multiline heredoc" || bad "multiline heredoc" "out=$out"

"$RUN" "$(b64 'cd /tmp && export AT_TEST_CANARY=yes')" >/dev/null
out="$("$RUN" "$(b64 'echo "$PWD:$AT_TEST_CANARY"')")"
"$RUN" "$(b64 "cd $HOME && unset AT_TEST_CANARY")" >/dev/null
case "$out" in
  /tmp:yes|/private/tmp:yes) ok "cd + export persist across invocations" ;;
  *) bad "cd + export persist across invocations" "got $out" ;;
esac

t0=$SECONDS
"$RUN" "$(b64 'echo pre-abort; echo ===; echo never')" >/dev/null 2>&1; rc=$?
el=$((SECONDS - t0))
[ $rc -ne 0 ] && [ $el -lt 15 ] && ok "zsh expansion abort fails fast (rc=$rc, ${el}s)" \
  || bad "zsh expansion abort fails fast" "rc=$rc elapsed=${el}s"

t0=$SECONDS
AGENT_TERM_TIMEOUT=3 "$RUN" "$(b64 'sleep 30')" >/dev/null 2>&1; rc=$?
el=$((SECONDS - t0))
[ $rc -eq 124 ] && [ $el -lt 15 ] && ok "timeout aborts with rc 124 (${el}s)" \
  || bad "timeout aborts with rc 124" "rc=$rc elapsed=${el}s"

out="$("$RUN" "$(b64 'echo recovery-after-timeout')")"
[ "$out" = "recovery-after-timeout" ] && ok "pane recovers after timeout C-c" || bad "pane recovers after timeout C-c" "out=$out"

out="$("$RUN" "$(b64 'ls --color=force /tmp >/dev/null; printf "\033[31mred\033[0m\n"')")"
if printf '%s' "$out" | LC_ALL=C grep -q $'\033'; then
  bad "ANSI stripped from agent-facing output" "escape bytes present"
else
  [ "$out" = "red" ] && ok "ANSI stripped from agent-facing output" || bad "ANSI stripped" "out=$out"
fi

( "$RUN" "$(b64 'echo par-one-start && sleep 2 && echo par-one-end')" >/tmp/at-par1.$$ ) &
sleep 0.3
out2="$("$RUN" "$(b64 'echo par-two')")"
wait
out1="$(cat /tmp/at-par1.$$)"; rm -f /tmp/at-par1.$$
[ "$out2" = "par-two" ] && [ "$out1" = "par-one-start
par-one-end" ] && ok "concurrent calls serialize cleanly" || bad "concurrent calls serialize cleanly" "out1=$out1 out2=$out2"

# Bug A regression (2026-08-01): pagers must be tamed even when the session
# was created OUTSIDE the wrapper (the SPC c V / SPC c L attach path) —
# git piping through `less` in an untamed pane used to hang until the
# 600s timeout with rc 124.
TMUX_T="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
"$TMUX_T" kill-session -t agent 2>/dev/null; sleep 1
"$TMUX_T" new-session -d -s agent 2>/dev/null; sleep 0.5
t0=$SECONDS
out="$(AGENT_TERM_TIMEOUT=15 "$RUN" "$(b64 'git -C ~/.dotfiles log --oneline -60')")"; rc=$?
el=$((SECONDS - t0))
lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[ $rc -eq 0 ] && [ $el -lt 10 ] && [ "$lines" = "60" ] \
  && ok "pager tamed in externally-created session (git log, ${el}s)" \
  || bad "pager tamed in externally-created session" "rc=$rc elapsed=${el}s lines=$lines"

# ── Layer 2: rewrite hook bypass rules ─────────────────────────────────────
section "Layer 2 — agent-tmux-hook.sh rewrite rules"
HOOK="$SCRIPTS/agent-tmux-hook.sh"

rm -f "$FLAG"
out="$(printf '{"tool_input":{"command":"echo hi"}}' | "$HOOK")"
[ -z "$out" ] && ok "flag off → silent (no rewrite)" || bad "flag off → silent" "$out"

touch "$FLAG"
out="$(printf '{"tool_input":{"command":"echo hi","description":"d","timeout":5000}}' | "$HOOK")"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.updatedInput | (.command | contains("agent-term-run.sh")) and .description == "d" and .timeout == 5000' >/dev/null 2>&1; then
  ok "flag on → rewrites, preserves other tool_input fields"
else
  bad "flag on → rewrites, preserves other tool_input fields" "$out"
fi
for case in \
  'background:{"tool_input":{"command":"npm run dev","run_in_background":true}}' \
  'tmux-command:{"tool_input":{"command":"tmux kill-server"}}' \
  'already-wrapped:{"tool_input":{"command":"~/x/agent-term-run.sh abc"}}' \
  'empty-command:{"tool_input":{}}'; do
  name="${case%%:*}"; json="${case#*:}"
  out="$(printf '%s' "$json" | "$HOOK")"
  [ -z "$out" ] && ok "bypass: $name" || bad "bypass: $name" "$out"
done
rm -f "$FLAG"

# ── Layer 3: ACP transform (gold payload shapes, adapter 0.54.1) ──────────
section "Layer 3 — ACP terminal-channel transform (batch elisp)"
if [ -x "$EMACS_BATCH" ]; then
  el=$(mktemp /tmp/at-acp-test-XXXXXX.el)
  cat >"$el" <<'ELISP'
(add-to-list 'load-path (expand-file-name "~/.dotfiles/macos/emacs/.emacs.d/lisp"))
(require 'agent-terminal)
(defun u (json) (json-parse-string json :object-type 'alist :null-object nil :false-object nil))
;; data update: no content key at all -> block injected
(let ((x (u "{\"_meta\":{\"terminal_output\":{\"terminal_id\":\"t\",\"data\":\"hello\"}},\"sessionUpdate\":\"tool_call_update\"}")))
  (agent-terminal--acp-transform-update x)
  (unless (string-match-p "```console\nhello\n```"
                          (map-nested-elt (aref (map-elt x 'content) 0) '(content text)))
    (error "data-injection failed")))
;; completed failure: rawOutput + exit 3 -> block + badge
(let ((x (u "{\"sessionUpdate\":\"tool_call_update\",\"rawOutput\":\"boom\",\"content\":[{\"type\":\"terminal\",\"terminalId\":\"t\"}],\"_meta\":{\"terminal_exit\":{\"terminal_id\":\"t\",\"exit_code\":3,\"signal\":null}}}")))
  (agent-terminal--acp-transform-update x)
  (let ((text (map-nested-elt (aref (map-elt x 'content) 0) '(content text))))
    (unless (and (string-match-p "boom" text) (string-match-p "✗ exit 3" text))
      (error "failure-badge failed: %S" text))))
;; placeholder tool_call -> dropped, nothing invented
(let ((x (u "{\"sessionUpdate\":\"tool_call\",\"content\":[{\"type\":\"terminal\",\"terminalId\":\"t\"}],\"_meta\":{\"terminal_info\":{\"terminal_id\":\"t\"}}}")))
  (agent-terminal--acp-transform-update x)
  (let ((c (map-elt x 'content)))
    (unless (or (null c) (= 0 (length c))) (error "placeholder not dropped"))))
;; capability advice against real acp.el
(add-to-list 'load-path (expand-file-name "~/.emacs.d/elpaca/repos/acp"))
(require 'acp)
(advice-add 'acp-make-initialize-request :filter-return #'agent-terminal--acp-add-capability)
(let* ((req (acp-make-initialize-request :protocol-version 1))
       (caps (alist-get 'clientCapabilities (alist-get :params req))))
  (unless (equal (alist-get '_meta caps) '((terminal_output . t)))
    (error "capability advice failed: %S" caps)))
(princ "ELISP-OK\n")
ELISP
  if "$EMACS_BATCH" --batch -l "$el" 2>&1 | grep -q "ELISP-OK"; then
    ok "transform + capability advice (gold payloads, real acp.el)"
  else
    bad "transform + capability advice" "run: $EMACS_BATCH --batch -l $el"
  fi
  rm -f "$el"
else
  printf '  SKIP: %s not found\n' "$EMACS_BATCH"
fi

# ── UX: window & rendering behavior (headless ERT) ─────────────────────────
section "UX — windows, faces, tail-follow, truncation (batch ERT)"
if [ -x "$EMACS_BATCH" ]; then
  uxout="$("$EMACS_BATCH" --batch -L "$LISP" -L "$EMACSD/tests" \
      -l agent-terminal.el -l agent-terminal-ux-tests.el \
      --eval "(ert-run-tests-batch-and-exit '(and \"^atux-\" (not (tag :live))))" 2>&1)"
  if printf '%s' "$uxout" | grep -q ", 0 unexpected"; then
    ok "UX suite: $(printf '%s' "$uxout" | grep -o 'Ran [0-9]* tests' | head -1)"
  else
    bad "UX suite" "$(printf '%s' "$uxout" | grep 'FAILED' | tr '\n' ' ')"
  fi
else
  printf '  SKIP: %s not found\n' "$EMACS_BATCH"
fi

# ── Optional: UX suite inside the running Emacs (visible) ──────────────────
if [ "$INEMACS" = 1 ]; then
  section "UX — inside your running Emacs (watch your frame)"
  if emacsclient --eval "t" >/dev/null 2>&1; then
    liveout="$(emacsclient --eval "(progn (load \"$EMACSD/lisp/agent-terminal.el\" nil t) (load \"$EMACSD/tests/agent-terminal-ux-tests.el\" nil t) (agent-terminal-ux-run t))" 2>&1 | tr -d '"')"
    case "$liveout" in
      *FAILURES*) bad "live-daemon UX suite" "$liveout" ;;
      */*passed*) ok "live-daemon UX suite: $liveout" ;;
      *) bad "live-daemon UX suite" "$liveout" ;;
    esac
  else
    printf '  SKIP: no Emacs daemon\n'
  fi
fi

# ── Optional: live end-to-end through interception ─────────────────────────
if [ "$LIVE" = 1 ]; then
  section "Live — headless claude through tmux interception"
  touch "$FLAG"
  LMARK="at-live-$$"
  out="$(echo "Run exactly this bash command and show raw output: echo $LMARK" \
    | claude -p --model claude-haiku-4-5-20251001 --allowedTools "Bash" 2>&1)"
  rm -f "$FLAG"
  printf '%s' "$out" | grep -q "$LMARK" && ok "agent received clean output through wrapper" \
    || bad "agent received clean output through wrapper" "$out"
  tmux capture-pane -t agent -p 2>/dev/null | grep -q "$LMARK" \
    && ok "command visibly executed in the tmux pane" \
    || bad "command visibly executed in the tmux pane"
fi

# ── Summary ────────────────────────────────────────────────────────────────
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
