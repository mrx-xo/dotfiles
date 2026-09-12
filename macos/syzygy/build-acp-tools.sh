#!/bin/bash
# Build acp-multiplex + acp-mobile at the reviewed/pinned commits (R2.4/R2.5,
# ~/docs/prd-remote-agent-access.md). Installs into ~/.local/bin.
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
# acp-multiplex: 3874a5b (thought identity across replay)
# + local 050a7b4 (every matched prompt response closes its turn: errors, agent exit, failed forward; sessionId from the request; queued prompts share one open/close)
# + local 0173b23 (explicit secondary replay start/complete markers before queued live delivery)
ACP_MULTIPLEX_COMMIT="0173b232ac1319e6f14e3159e4e3e9df76eb0fbd"
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
# + local 75fb757 (cue-prefix styling table mirrors agent-shell; Separately: blue aside)
# + local cd7efe9 (push tap lands on the chat after iOS reload / cold launch)
# + local f7f6fcf (home screen named Orrery: header + ids + comments)
# + local a004620 (Clone in the chat menu: /api/spawn cloneOf -> fresh convo, same model/mode/cwd)
# + local 909a7be (resume exact agent-recall conversations from History)
# + local 6fd71e2 (resumable/resumeReason survive the transcriptInfo decode)
# + local 198ad20 (push tap works with the app already open: startMessages + BroadcastChannel)
# + local 9487f6a (turn nav arrows jump between prompts and responses)
# + local d5752f8 (turn nav starts hidden; Show/Hide turn nav in the chat menu)
# + local 0aa2c47 (in-app banner for pushes while the app is already open)
# + local 576c1f8 (Settings page: gear in Orrery header; turn nav corner top/bottom + left/right)
# + local e88bee3 (turn nav auto-shows in History transcripts; markup moved to body root)
# + local 69a2cfa (one elisp call helper for the daemon bridges; label/push/kill migrated)
# + local 02f0c4b (standalone viewport nudge on launch/resume; History turn nav on one-prompt transcripts; hold chat bottom while replay settles)
# + local 37fec37 (standalone launch: passes from 0ms, bottom chrome veiled until the first recompute clears)
# + local adf76d0 (spawn presets: Astra chip -> GPT-6-Astra, full access)
# + local 297f14f (iOS: repair viewport during keyboard dismissal, removing the delayed bottom jump)
# + local 8fb76c8 (Soft motion: slower sends, stable streaming word reveals, and smoother swipes)
# + local 7e34d1b (reconnect UX: yellow grace state, 400ms first retry, no-blank replay, 25s keepalive + 60s silence timer, foreground redial)
# + local 60850a9 (busy state follows prompt turns, so background-task continuations no longer leave a chat stuck on thinking; composer drafts are per chat)
# + local e985348 (Fork entry in the chat menu: /api/fork through syzygy-fork-json, greyed out for agents without session/fork)
# + local 3b2c3f0 (rig-fed pickers: spawn presets from mr-x/agent-shell-presets, Model entry in the chat menu over agent-shell models, project picker with filter over project-dashboard-projects merged with live cwds)
# + local eb2f552 (spawn sheet: path box is a project combobox with a vertical filtered list, rows pick on touch pointerup so the keyboard can stay up, sheet 94 percent tall)
# + local 1da9116 (spawn sheet: project list is a dropdown, opens on focus, collapses on pick)
# + local 434b4a6 (catalogue and pin from the phone: /api/catalogue + /api/pin over the syzygy-recall bridges, Pin chat and Catalogue in the chat menu, pinned chats first in the Orrery, History Catalogued chip, #tag search, catalogue/uncatalogue in the transcript view)
# + local 3d1dd9a (scroll button and bottom turn nav clear the thinking bar as it appears and disappears)
# + local b131b40 (in-app push delivery, presence, escalation: /api/presence, statuses carries pushes, acp-mobile/push socket frames, parked pushes escalate to Web Push when the page leaves unread within 20s; /api/push-inbox removed)
# + local 4686dea (jump-to-bottom waits for explicit replay completion and rendered assets; delayed Loading chat indicator; requires new multiplex sessions)
# + local 04425d5 (mermaid fences render as diagrams: engine embedded under assets/ and lazily injected, config exported from the rig via /api/mermaid-config, full-screen inspector with pinch/pan/double-tap-fit, fence source carried base64 in data-code which also fixes multi-line copy)
# + local 733378a (New Chat: independent agent/model/permissions/effort, searchable pickers, editable presets, saved drafts and exact launch recovery; requires syzygy-launch.el)
# + local 306c5dd (preset chips accept horizontal touch swipes; verified with a browser touch gesture)
# + local 68fe3bd (in-chat model search appears on overflow, stays above results, and clears on reopen)
ACP_MOBILE_COMMIT="68fe3bd0da36e478bd00aadf6b020dbd99c80259"

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

# The phone's 8090 instance is a launchd job that keeps the old binary in
# memory until relaunched.  Kickstart it when it is loaded (MrX); on boxes
# without the agent this is a no-op.  acp-multiplex needs nothing: each
# agent-shell session spawns its own, so new sessions pick up the build.
if launchctl print "gui/$(id -u)/com.marcosandrade.acp-mobile" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/com.marcosandrade.acp-mobile"
  echo "restarted com.marcosandrade.acp-mobile"
fi
