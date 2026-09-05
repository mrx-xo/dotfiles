#!/bin/bash
# Build acp-multiplex + acp-mobile at the reviewed/pinned commits (R2.4/R2.5,
# docs/prd-remote-agent-access.md). Installs into ~/.local/bin.
#
# Both tools build from the mrx-xo forks: reviewed SYZYGY changes land as
# commits on their `syzygy` branches, and the pinned hashes may not exist on
# ElleNajt's upstream. Fork workflow: commit in ~/src/<repo>, push to
# `fork syzygy`, then bump the exact pin here.
#
# Usage: ./build-acp-tools.sh
set -euo pipefail

SRC_DIR="$HOME/src"
BIN_DIR="$HOME/.local/bin"

# Pinned commits reviewed in PRD Phase 0
ACP_MULTIPLEX_COMMIT="3874a5b90a174da8d166ebf08e355fa1f20edfd2"
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
# + local 1c1dbb7 (tool cards: ACP-neutral kind rendering, Claude + Codex)
# + local d944f17 (history API: /api/transcripts + /api/transcript)
# + local 3602b0b (history UI: browse agent-recall transcripts, agent badges)
# + local 69546b7 (spawn presets: Codex chips — Sol / Sol Max full-access)
# + local a844c5e (provider icons on live chat + history cards)
# + local ffe4bde (mobile context refs, live status sync, integrated code-copy header)
# + local ea08d3e (probe: session id from notifications, fixes labels/status on resumed convos)
# + local 8309031 (agent-recall search, labeled History, persistent mobile dock)
# + local dc290bd (iOS: keep search dock at safe-area bottom on launch)
# + local 999f3b3 (iOS: keep body viewport stable on launch)
# + local fc3c55d (Markdown-aware live/replayed thought progress)
# + local 5497ac1 (thought progress: tool-style activity cards)
# + local b66dff2 (sent images: live/replay rendering and memory bounds)
# + local d5ec75d (answer-only ADHD cue-prefix highlighting)
# + local 0ea33a6 (ordered lists; pins re-render on the current renderer)
# + local dff199a (lists: agent-shell panel + yellow bold markers)
# + local 34baede (lists: no panel, 12px gap between items)
# + local 8ce1b8c (iOS: send on the first tap while the keyboard is up)
# + local 7e990b2 (iOS standalone: restore the layout viewport after the keyboard)
# + local 58cff90 (send motion visible; bubble stays above the thinking bar)
# + local 3403106 (jump-to-bottom snaps to the real bottom, then auto-follows)
# + local bc0b684 (answered permissions in replay no longer look busy)
# + local eb3d212 (phone push bell in chat header; /api/push + push.json sidecar)
# + local e2a6555 (filled bell on session cards when push is armed)
# + local 994b258 (Web Push: /api/notify fan-out, sw.js, manifest, https link)
ACP_MOBILE_COMMIT="994b258463aef1f5bbf95681fbe7ed85e0ee5b3a"

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

build mrx-xo acp-multiplex "$ACP_MULTIPLEX_COMMIT"
build mrx-xo acp-mobile "$ACP_MOBILE_COMMIT"
