#!/usr/bin/env bash
# Build a disposable git repo of awkward diffs for the Emacs review viewer
# (review-session, SPC g R G).  Rerun any time: it rebuilds from scratch.
#
#   review-fixture-repo.sh [DEST]      default: ~/src/review-fixtures
#
# Layout: `main` holds the base commit; `review-cases` (checked out) adds three
# commits on top, then leaves one staged and one unstaged edit.  Every range
# preset in the picker therefore has something to show:
#   uncommitted, staged, HEAD~1..HEAD, HEAD~3..HEAD, main...HEAD
#
# Cases, one file each:
#   long-line.md          change at column ~4000 of one very long line
#   big.md                ~100 KB Markdown, three scattered edits (speed)
#   many-hunks.el         40 defuns, five separate hunks (M-j / M-k, labels)
#   start-and-end.txt     first and last line change (scroll edges)
#   whitespace.txt        trailing spaces and tab/space swaps only
#   wide-chars.md         CJK and accented text (string-width, alignment)
#   no-newline.txt        last line changes, no newline at end of file
#   crlf.txt              CRLF line endings converted to LF
#   empty-to-content.txt  empty file gains content
#   added.py              new file
#   deleted.txt           removed file
#   renamed-new.txt       renamed from renamed-old.txt plus one edit
#   script.sh             mode change only (chmod +x), no content change
#   binary.bin            binary content change
#   services/.../with-a-long-file-name-for-the-panel.yaml   deep path
#   worktree/staged.txt   staged, uncommitted edit
#   worktree/unstaged.txt unstaged edit
set -euo pipefail

DEST="${1:-$HOME/src/review-fixtures}"
MARKER=".review-fixture"

if [ -e "$DEST" ]; then
  if [ ! -e "$DEST/$MARKER" ]; then
    echo "refusing: $DEST exists and is not a review fixture repo" >&2
    exit 1
  fi
  rm -rf "$DEST"
fi
mkdir -p "$DEST"
cd "$DEST"

export GIT_AUTHOR_NAME="Review Fixture" GIT_AUTHOR_EMAIL="fixture@example.invalid"
export GIT_COMMITTER_NAME="Review Fixture" GIT_COMMITTER_EMAIL="fixture@example.invalid"
git init -q -b main
git config commit.gpgsign false
git config core.hooksPath /dev/null
git config core.autocrlf false

tick=0
commit() {
  tick=$((tick + 1))
  local date="2026-01-01T00:0${tick}:00Z"
  git add -A
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" git commit -q -m "$1"
}

# Portable in-place sed (BSD and GNU).
edit() { local f="$1"; shift; sed "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

long_line() {
  local i s=""
  for i in $(seq 1 450); do s+="token$i "; done
  printf '%s%s\n' "$s" "$1"
}

big_md() {
  local i
  for i in $(seq 1 700); do
    printf '## Section %d\n\nParagraph %d with `inline code`, **bold**, and a [link](https://example.invalid/%d).\n- item one for section %d\n- item two for section %d\n\n' \
      "$i" "$i" "$i" "$i" "$i"
  done
}

many_hunks_el() {
  local i
  printf ';;; many-hunks.el --- fixture -*- lexical-binding: t; -*-\n\n'
  for i in $(seq 1 40); do
    printf '(defun fixture-fn-%d (x)\n  "Return X scaled by %d."\n  (let ((factor %d))\n    (* x factor)))\n\n' "$i" "$i" "$i"
  done
  printf '(provide (quote many-hunks))\n'
}

# ---- base commit on main ----
touch "$MARKER"
printf 'Review viewer fixtures.  Rebuilt by review-fixture-repo.sh.\n' > README.md
{ printf '# Long line\n\n'; long_line "the original ending of this line."; printf '\nAfter.\n'; } > long-line.md
big_md > big.md
many_hunks_el > many-hunks.el
seq 1 50 | sed 's/^/line /' > start-and-end.txt
printf 'alpha beta\n\tindented with a tab\n    indented with spaces\ngamma\n' > whitespace.txt
printf '# Wide characters\n\n日本語のテキストです。\nCafé, naïve, façade.\n中文字符测试行。\nplain ascii line\n' > wide-chars.md
printf 'one\ntwo\nthree' > no-newline.txt
printf 'first\r\nsecond\r\nthird\r\n' > crlf.txt
: > empty-to-content.txt
printf 'this file will be deleted\nsecond line\n' > deleted.txt
printf 'rename me\nkeep this line\nchange this line\n' > renamed-old.txt
printf '#!/bin/sh\necho fixture\n' > script.sh
printf 'BIN\000\001\002\003header\000payload-v1\000\377\376' > binary.bin
mkdir -p services/really/deeply/nested/configuration/directory worktree
printf 'name: fixture\nreplicas: 1\nimage: example/app:1.0\n' \
  > services/really/deeply/nested/configuration/directory/with-a-long-file-name-for-the-panel.yaml
printf 'staged base\n' > worktree/staged.txt
printf 'unstaged base\n' > worktree/unstaged.txt
commit "base"

# ---- review-cases branch: three commits ----
git switch -q -c review-cases

{ printf '# Long line\n\n'; long_line "a CHANGED ending, far to the right."; printf '\nAfter.\n'; } > long-line.md
edit big.md -e 's/^Paragraph 40 with/Paragraph 40 (edited) with/' \
            -e 's/^- item two for section 350$/- item two for section 350, revised/' \
            -e 's/^## Section 690$/## Section 690 renamed/'
edit many-hunks.el -e 's/(let ((factor 3))/(let ((factor 33))/' \
                   -e 's/Return X scaled by 12\./Return X multiplied by 12./' \
                   -e 's/^(defun fixture-fn-25 (x)$/(defun fixture-fn-25 (x \&optional y)/' \
                   -e 's/(let ((factor 39))/(let ((factor (+ 39 1)))/'
printf '(defun fixture-fn-extra ()\n  "Added at the end."\n  nil)\n' >> many-hunks.el
edit start-and-end.txt -e 's/^line 1$/line one (changed)/' -e 's/^line 50$/line fifty (changed)/'
commit "content edits: long line, big file, hunks, edges"

printf 'alpha beta  \n    indented with a tab\n\tindented with spaces\ngamma\n' > whitespace.txt
printf '# Wide characters\n\n日本語のテキストでした。\nCafé, naïve, façades.\n中文字符测试行。\nplain ascii line\n' > wide-chars.md
printf 'one\ntwo\nTHREE' > no-newline.txt
printf 'first\nsecond\nthird\n' > crlf.txt
printf 'now it has content\n' > empty-to-content.txt
commit "invisible and encoding edits"

printf 'def added():\n    """New file."""\n    return 42\n' > added.py
git rm -q deleted.txt
git mv renamed-old.txt renamed-new.txt
edit renamed-new.txt -e 's/^change this line$/changed after the rename/'
chmod +x script.sh
printf 'BIN\000\001\002\003header\000payload-v2\000\377\376' > binary.bin
edit services/really/deeply/nested/configuration/directory/with-a-long-file-name-for-the-panel.yaml \
  -e 's/replicas: 1/replicas: 3/'
commit "file-level edits: add, delete, rename, mode, binary, deep path"

# ---- uncommitted state ----
printf 'staged base\nstaged addition\n' > worktree/staged.txt
git add worktree/staged.txt
printf 'unstaged base\nunstaged addition\n' > worktree/unstaged.txt

echo "Review fixture repo ready: $DEST"
echo "Branch review-cases: 3 commits over main, plus one staged and one unstaged edit."
git --no-pager diff --stat main...HEAD | tail -1
