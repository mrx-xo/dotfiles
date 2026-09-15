#!/bin/bash
# Named sandbox lifecycle; every shutdown rechecks daemon name, init path, PID.
# --fresh preserves the previous sandbox beside the filtered replacement.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="${SANDBOX_DIR:-$HOME/.emacs-sandbox}"
SOURCE_DIR="${EMACS_CONFIG_SOURCE:-$HOME/.emacs.d}"
EMACS="${EMACS:-/opt/homebrew/opt/emacs-plus@30/bin/emacs}"
EMACSCLIENT="${EMACSCLIENT:-/opt/homebrew/opt/emacs-plus@30/bin/emacsclient}"
SOCKET_NAME="sandbox"
AUTO_TEST=""; KILL_DAEMON=""; FRESH=""; RESTART=""; DISPLAY_IDX=""
RUNTIME_ARGS=()
[[ -z "${EMACS_RUNTIME_DIRECTORY:-}" ]] || RUNTIME_ARGS=(--runtime-directory "$EMACS_RUNTIME_DIRECTORY")
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=yes ;;
        --restart) RESTART=yes ;;
        --kill) KILL_DAEMON=yes ;;
        --test) AUTO_TEST=yes ;;
        *) echo "Unknown sandbox option: $arg" >&2; exit 2 ;;
    esac
done
SANDBOX_DIR="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SANDBOX_DIR")"
# Reject control characters before embedding the path in a Lisp string.
[[ "$SANDBOX_DIR" != *$'\n'* && "$SANDBOX_DIR" != *$'\r'* ]] || exit 2
INIT_QUOTED=${SANDBOX_DIR//\\/\\\\}
INIT_QUOTED=${INIT_QUOTED//\"/\\\"}
IDENTITY="(and (equal (daemonp) \"sandbox\") (equal server-name \"sandbox\") (equal (file-truename user-emacs-directory) \"$INIT_QUOTED/\"))"

daemon_pid() {
    local result
    if result=$(timeout 5 "$EMACSCLIENT" --socket-name="$SOCKET_NAME" --eval "(if $IDENTITY (emacs-pid) nil)" 2>/dev/null); then
        if [[ "$result" =~ ^[0-9]+$ && "$result" != 0 ]]; then
            printf '%s\n' "$result"
        else
            echo "Sandbox socket identity mismatch; refusing lifecycle action" >&2
            return 2
        fi
    else
        local status=$?
        if [[ "$status" == 124 || "$status" == 137 ]]; then
            echo "Sandbox socket unresponsive; refusing lifecycle action" >&2
            return 3
        fi
        return 1
    fi
}

save_display() {
    local pid
    if pid=$(daemon_pid); then
        if command -v yabai >/dev/null && command -v jq >/dev/null; then
            DISPLAY_IDX=$(yabai -m query --windows | jq -r ".[] | select(.app == \"Emacs\" and .pid == $pid) | .display" | head -1) || true
        fi
    else
        local status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
}

kill_daemon() {
    local pid status attempt
    if pid=$(daemon_pid); then
        # The check and shutdown occur in one request; socket replacement or
        # PID changes between the probe and this request cannot target a peer.
        timeout 5 "$EMACSCLIENT" --socket-name="$SOCKET_NAME" --eval "(when (and $IDENTITY (= (emacs-pid) $pid)) (kill-emacs))" >/dev/null 2>&1 || true
        for ((attempt=0; attempt<50; attempt++)); do
            if ! ps -p "$pid" -o pid= >/dev/null 2>&1; then echo "Sandbox stopped"; return 0; fi
            sleep 0.1
        done
        echo "Sandbox did not exit; preserving its files" >&2
        return 1
    else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
        # No responding sandbox socket.  A launch may still be in progress;
        # the helper's lock, not this wrapper, decides whether one can start.
        echo "Sandbox not running"
    fi
}

if [[ -n "$KILL_DAEMON" ]]; then
    kill_daemon
    exit 0
fi
if [[ -n "$FRESH" || -n "$RESTART" ]]; then
    save_display
    kill_daemon
fi

if [[ ! -d "$SANDBOX_DIR" || -n "$FRESH" ]]; then
    COPY_ARGS=()
    [[ -z "$FRESH" ]] || COPY_ARGS=(--replace)
    python3 "$SCRIPT_DIR/emacs-sandbox-copy.py" "$SOURCE_DIR" "$SANDBOX_DIR" ${COPY_ARGS[@]+"${COPY_ARGS[@]}"} ${RUNTIME_ARGS[@]+"${RUNTIME_ARGS[@]}"}
    # 1. Enable title bar (comment out undecorated-round)
    sed -i '' "s/(add-to-list 'default-frame-alist '(undecorated-round . t))/;; SANDBOX: (add-to-list 'default-frame-alist '(undecorated-round . t))/" "$SANDBOX_DIR/early-init.el"

    # 2. Create sandbox indicator file
    cat > "$SANDBOX_DIR/sandbox-indicator.el" << 'EOF'
;;; sandbox-indicator.el --- Visual indicator for sandbox Emacs -*- lexical-binding: t; -*-

;; Title bar shows SANDBOX
(setq frame-title-format '("SANDBOX - " "%b"))

;; Doom modeline custom segment
(with-eval-after-load 'doom-modeline
  (doom-modeline-def-segment sandbox
    "Sandbox indicator segment."
    (propertize " SANDBOX " 'face '(:background "#ff6b6b" :foreground "white" :weight bold)))

  (doom-modeline-def-modeline 'main
    '(bar workspace-name window-number sandbox modals matches follow buffer-info remote-host buffer-position word-count parrot selection-info)
    '(compilation objed-state misc-info persp-name battery grip irc mu4e gnus github debug repl lsp minor-modes input-method indent-info buffer-encoding major-mode process vcs check time))

  ;; This file loads AFTER doom-modeline has already installed its default
  ;; modeline, so redefining `main' above does not take effect on its own.
  ;; Re-activate it now, and again once startup settles (doom-modeline-mode
  ;; can re-apply the default modeline late in init). Without this the
  ;; SANDBOX badge silently vanishes on a fresh sandbox.
  (doom-modeline-set-modeline 'main t)
  (run-at-time 1 nil (lambda () (doom-modeline-set-modeline 'main t))))

(message "Running in SANDBOX mode - your real config is safe!")

(provide 'sandbox-indicator)
;;; sandbox-indicator.el ends here
EOF

    # 3. Add loader to init.el
    echo '' >> "$SANDBOX_DIR/init.el"
    echo ';; Sandbox visual indicator' >> "$SANDBOX_DIR/init.el"
    echo '(load (expand-file-name "sandbox-indicator.el" user-emacs-directory) t)' >> "$SANDBOX_DIR/init.el"
    # tab-lab: major-pane styling playground (C-c l to build the scene).
    # The file rides along in the .emacs.d copy; only sandbox init loads it.
    echo ';; Sandbox tab-lab (major-pane styling playground)' >> "$SANDBOX_DIR/init.el"
    echo '(load (expand-file-name "sandbox/tab-lab.el" user-emacs-directory) t)' >> "$SANDBOX_DIR/init.el"

    echo "Sandbox configuration copied"
fi

if pid=$(daemon_pid); then
    echo "Sandbox already running"
else
    status=$?
    [[ "$status" == 1 ]] || exit "$status"
    # Readiness only bounds the wait; a slow start (package builds on the
    # Air) keeps running and a rerun attaches to it once it answers.
    "$SCRIPT_DIR/emacs-daemon-run.sh" --server "$SOCKET_NAME" --init-directory "$SANDBOX_DIR" --emacs "$EMACS" --emacsclient "$EMACSCLIENT" --timeout "${EMACS_START_TIMEOUT:-120}" ${RUNTIME_ARGS[@]+"${RUNTIME_ARGS[@]}"}
fi

if [[ -n "$AUTO_TEST" ]]; then
    timeout 5 "$EMACSCLIENT" --socket-name="$SOCKET_NAME" -c -n --eval "(run-with-timer 1 nil #'mr-x/sandbox-test-env)"
else
    timeout 5 "$EMACSCLIENT" --socket-name="$SOCKET_NAME" -c -n
fi
if [[ "$DISPLAY_IDX" =~ ^[0-9]+$ ]]; then
    if pid=$(daemon_pid); then
        wid=$(yabai -m query --windows | jq -r ".[] | select(.app == \"Emacs\" and .pid == $pid) | .id" | head -1) || true
        if [[ "${wid:-}" =~ ^[0-9]+$ ]]; then
            yabai -m window "$wid" --display "$DISPLAY_IDX"
            yabai -m window "$wid" --focus
        fi
    fi
fi
