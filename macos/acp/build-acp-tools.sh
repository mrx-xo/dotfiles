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
# a2b52e4 (upstream) + local 71d9f81: persistent auth cookie + keep
# authkey in URL so iOS home-screen web clips stay self-authenticating
ACP_MOBILE_COMMIT="71d9f81"

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
