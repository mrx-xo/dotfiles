#!/bin/bash
# Build acp-multiplex + acp-mobile at the reviewed/pinned commits (R2.4/R2.5,
# docs/prd-remote-agent-access.md). Installs into ~/.local/bin.
#
# acp-mobile builds from the Marx-A00 fork: local UI work lands as commits
# on its `syzygy` branch (history log below), and the pinned hashes don't
# exist on ElleNajt's upstream. acp-multiplex has no local commits and
# builds from upstream. Fork workflow: commit in ~/src/acp-mobile, push to
# `fork syzygy`, bump the pin here.
#
# Usage: ./build-acp-tools.sh
set -euo pipefail

SRC_DIR="$HOME/src"
BIN_DIR="$HOME/.local/bin"

# Pinned commits reviewed in PRD Phase 0
ACP_MULTIPLEX_COMMIT="d987060"
# a2b52e4 (upstream) + local 71d9f81 (self-authenticating web clips)
# + local 8787b16 (gruvbox theme, real session names via replay preview
# + labels.json sidecar, iOS standalone polish)
# + local 714ab25 (rig-match: Iosevka Term Slab webfont, org-level
# grayscale headers, purple links)
# + local 7ba93e5 (headers match agent-shell's gruvbox org-level remap)
# + local 240e0a7 (pinned messages: long-press pin, header pin icon list)
# + local 405325a (global pinned view from Sessions screen)
# + local d3dd311 (iOS: no page-wide selection highlight on long-press)
# + local 720daad (global pinned view: chat cards, tap into convo pins)
# + local cb2dbb6 (chat header: three-dot menu w/ Pinned + Kill)
# + local 1c84a11 (nav header: title toggles Sessions/Projects, no ↻)
# + local 1b954f9 (nav caret: SVG chevron, vertically centered)
# + local 433ae84 (copy: HTTP-safe clipboard fallback, selectable bubbles)
# + local e8120da (peek: markdown + chat-style bubbles in preview sheet)
ACP_MOBILE_COMMIT="e8120da"

mkdir -p "$SRC_DIR" "$BIN_DIR"

build() {
  local owner="$1" repo="$2" commit="$3"
  local dir="$SRC_DIR/$repo"
  if [[ ! -d "$dir" ]]; then
    git clone "https://github.com/$owner/$repo.git" "$dir"
  fi
  git -C "$dir" fetch --quiet
  git -C "$dir" checkout --quiet "$commit"
  (cd "$dir" && go build -o "$BIN_DIR/$repo" .)
  echo "built $repo @ $commit -> $BIN_DIR/$repo"
}

build ElleNajt acp-multiplex "$ACP_MULTIPLEX_COMMIT"
build Marx-A00 acp-mobile "$ACP_MOBILE_COMMIT"
