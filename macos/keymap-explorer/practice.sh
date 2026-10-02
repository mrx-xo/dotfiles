#!/usr/bin/env bash
# Refresh the local practice catalog; opening uses the agent Brave space.
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in
  ''|--refresh-only) ;;
  *) echo 'Usage: practice.sh [--refresh-only]' >&2; exit 2 ;;
esac
# Resolve paths within Emacs; filenames never enter Lisp source unescaped.
export IRIS_PRACTICE_DIR="$PWD"
emacsclient --eval '(let ((dir (getenv "IRIS_PRACTICE_DIR"))) (load-file (expand-file-name "export-bindings.el" dir)) (iris-practice-export (expand-file-name "practice-bindings.js" dir)))'
if [[ "${1:-}" != '--refresh-only' ]]; then
  agent-open "file://$PWD/index.html#practice"
fi
