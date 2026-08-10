#!/bin/bash
# Build acp-multiplex + acp-mobile at the reviewed/pinned commits (R2.4/R2.5,
# docs/prd-remote-agent-access.md). Installs into ~/.local/bin.
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
ACP_MOBILE_COMMIT="5ed97b6"

mkdir -p "$SRC_DIR" "$BIN_DIR"

build() {
  local repo="$1" commit="$2"
  local dir="$SRC_DIR/$repo"
  if [[ ! -d "$dir" ]]; then
    git clone "https://github.com/ElleNajt/$repo.git" "$dir"
  fi
  git -C "$dir" fetch --quiet
  git -C "$dir" checkout --quiet "$commit"
  (cd "$dir" && go build -o "$BIN_DIR/$repo" .)
  echo "built $repo @ $commit -> $BIN_DIR/$repo"
}

build acp-multiplex "$ACP_MULTIPLEX_COMMIT"
build acp-mobile "$ACP_MOBILE_COMMIT"
