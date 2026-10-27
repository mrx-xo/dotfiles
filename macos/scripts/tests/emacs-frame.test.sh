#!/usr/bin/env bash
# emacs-frame.test.sh — Cmd+Shift+E must never spawn a bare daemon.
# With a server answering, emacs-frame.sh opens a frame; without one it goes
# through emacs-daemon-start.sh (the diagnostic launcher), and if that launch
# is refused (one already starting) it waits with emacsclient-frame.sh.
set -u
SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$SCRIPTS/emacs-frame.sh" "$TMP/emacs-frame.sh"
cat > "$TMP/emacsclient" <<'STUB'
#!/bin/bash
echo "emacsclient $*" >> "$HOME/calls.log"
[ "${SERVER_UP:-}" = 1 ] || { echo "no server" >&2; exit 1; }
STUB
cat > "$TMP/emacs-daemon-start.sh" <<'STUB'
#!/bin/bash
echo "emacs-daemon-start.sh $*" >> "$HOME/calls.log"
exit "${START_RC:-0}"
STUB
cat > "$TMP/emacsclient-frame.sh" <<'STUB'
#!/bin/bash
echo "emacsclient-frame.sh $*" >> "$HOME/calls.log"
STUB
chmod +x "$TMP"/*.sh "$TMP/emacsclient"

pass=0; fail=0
check() {  # check <desc> <SERVER_UP> <START_RC> <expected calls.log>
  local desc="$1" up="$2" rc="$3" want="$4" got
  rm -f "$TMP/calls.log"
  HOME="$TMP" EMACSCLIENT="$TMP/emacsclient" SERVER_UP="$up" START_RC="$rc" \
    bash "$TMP/emacs-frame.sh" >/dev/null 2>&1
  got=$(cat "$TMP/calls.log" 2>/dev/null || echo -)
  if [ "$got" = "$want" ]; then echo "PASS: $desc"; pass=$((pass+1))
  else echo "FAIL: $desc"; echo "$got" | sed 's/^/  got: /'; fail=$((fail+1)); fi
}

check "server up: open a frame, start nothing" 1 0 \
"emacsclient --socket-name=server --alternate-editor=false --eval t
emacsclient --socket-name=server --alternate-editor=false -c -n"
check "no server: start through the launcher" 0 0 \
"emacsclient --socket-name=server --alternate-editor=false --eval t
emacs-daemon-start.sh "
check "no server, launch refused: wait for the one starting" 0 3 \
"emacsclient --socket-name=server --alternate-editor=false --eval t
emacs-daemon-start.sh 
emacsclient-frame.sh "

# Guards on the callers: no launch path may fall back to a bare daemon.
ROOT="$(cd "$SCRIPTS/../.." && pwd)"
if grep -q 'cmd + shift - e : ~/.dotfiles/macos/scripts/emacs-frame.sh' "$ROOT/macos/skhd/skhdrc"; then
  echo "PASS: skhd Cmd+Shift+E uses emacs-frame.sh"; pass=$((pass+1))
else echo "FAIL: skhd Cmd+Shift+E does not use emacs-frame.sh"; fail=$((fail+1)); fi
if grep -n -E -- '-a *(""|'"''"')|--alternate-editor=("|'"'"')?("|'"'"')?( |$)' "$ROOT/macos/skhd/skhdrc" "$ROOT/macos/.zshrc" "$ROOT"/macos/scripts/*.sh "$ROOT"/macos/hammerspoon/*.lua >/dev/null; then
  echo "FAIL: an emacsclient call still has an empty alternate editor"; fail=$((fail+1))
else echo "PASS: no empty alternate editor anywhere"; pass=$((pass+1)); fi
if grep -n -E "alias ecd=.*emacs --daemon" "$ROOT/macos/.zshrc" >/dev/null; then
  echo "FAIL: zsh alias ecd still starts a bare daemon"; fail=$((fail+1))
else echo "PASS: zsh alias ecd goes through the launcher"; pass=$((pass+1)); fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
