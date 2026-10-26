#!/usr/bin/env bash
# Run the SYZYGY ERT suite headless, without Elpaca or agent-shell.
#   shared/emacs/tests/run-syzygy-tests.sh [--emacs PATH]
# Exits with ERT's status. Works from any cwd (repo root is resolved from $0).
set -euo pipefail
cd "$(dirname "$0")/../../.."
root="$PWD"

emacs=/opt/homebrew/opt/emacs-plus@30/bin/emacs
if [[ "${1:-}" == "--emacs" ]]; then
  emacs="${2:?--emacs needs a path}"
  shift 2
fi

paths=("$root/shared/emacs/lisp/syzygy" "$root/macos/emacs/.emacs.d/lisp" "$root/macos/emacs/.emacs.d/tests")
[[ -d "$HOME/roaming/projects/agent-recall" ]] && paths+=("$HOME/roaming/projects/agent-recall")

args=()
for d in "${paths[@]}"; do args+=(-L "$d"); done
# The state directory is bound to a fresh temp dir before any test file loads,
# so a batch run can never touch the real ~/.acp-mobile sidecars.
args+=(--eval '(require (quote syzygy-state))'
       --eval '(setq syzygy-state-directory (file-name-as-directory (make-temp-file "syzygy-tests-" t)))')
while IFS= read -r f; do args+=(-l "$f"); done < <(printf '%s\n' "$root"/shared/emacs/lisp/syzygy/*-test.el | sort)
args+=(-l "$root/macos/emacs/.emacs.d/tests/syzygy-recall-tests.el")

exec timeout 600 "$emacs" --batch -Q "${args[@]}" -f ert-run-tests-batch-and-exit
