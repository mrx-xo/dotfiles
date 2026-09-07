#!/usr/bin/env bash
# What keys are already taken in evil? Ask the running Emacs, right now.
#
# Nothing is checked in on purpose: a saved keymap snapshot goes stale the
# moment a binding changes, and a stale one is worse than none because agents
# trust it. Regenerating is ~1s, so regenerate.
#
#   evil-key-survey.sh            brief report on stdout (~150 lines):
#                                 free leader keys + the gotchas. Read this
#                                 before proposing a binding.
#   evil-key-survey.sh --full     everything: stock-evil diff, per-mode
#                                 shadowing, every prefix tree. Writes a file
#                                 and prints its path (~1700 lines, ~6s).
#   evil-key-survey.sh --full OUT write the full report to OUT.
#
# Reads the live daemon over emacsclient and never modifies it. --full also
# runs an isolated `emacs -Q --batch` that loads only evil + goto-chg, to get a
# stock-evil baseline to diff against; that process does not touch the daemon.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/evil-key-survey"
EMACS="${EMACS:-/opt/homebrew/opt/emacs-plus@30/bin/emacs}"
export EKS_DIR="${EKS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/eks.XXXXXX")}"
trap 'rm -rf "$EKS_DIR"' EXIT

FULL=""
if [[ "${1:-}" == "--full" ]]; then FULL=1; shift; fi
OUT="${1:-}"
if [[ -n "$FULL" && -z "$OUT" ]]; then
  OUT="${TMPDIR:-/tmp}/evil-keymap-survey.md"
fi

emacsclient --eval "(progn (setq eks/dir \"$EKS_DIR\") (load-file \"$LIB/live-dump.el\"))" >/dev/null

if [[ -n "$FULL" ]]; then
  "$EMACS" -Q --batch -l "$LIB/vanilla-dump.el"
  python3 "$LIB/compose.py" --full "$OUT"
else
  python3 "$LIB/compose.py" ${OUT:+"$OUT"}
fi
