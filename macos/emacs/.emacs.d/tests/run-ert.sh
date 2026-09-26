#!/usr/bin/env bash
# Run ERT files headless with Elpaca's builds and this repo's lisp on the load path.
#   tests/run-ert.sh tests/review-store-test.el [more files]
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
for f in "$@"; do args+=(-l "$f"); done
exec timeout 300 /opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -Q \
  --eval '(progn (dolist (d (directory-files "~/.emacs.d/elpaca/builds" t "^[^.]")) (add-to-list (quote load-path) d)) (dolist (d (list "lisp" "lisp/syzygy" "tests")) (add-to-list (quote load-path) (expand-file-name d))))' \
  "${args[@]}" -f ert-run-tests-batch-and-exit
