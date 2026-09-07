#!/usr/bin/env bash
# Wire every installed CLI agent to the shared global instructions in ~/docs/agents/.
#
# The canon is two files, agent-agnostic and versioned in the private docs repo:
#   core.md          every agent, every role
#   orchestrator.md  session drivers and delegators only
#
# Claude and OpenCode resolve a real file pointer, so they reference the canon
# directly. Codex and Gemini resolve no import syntax in any form (verified
# 2026-09-07 with a control-and-canary test), so they get a copy of stub.md,
# which inlines the four hard rules and tells the agent to read the canon.
#
# Idempotent: safe to re-run. Run it on every machine after cloning the docs
# repo; the agent config files are per-machine and are not synced.

set -euo pipefail

AGENTS_DIR="$HOME/docs/agents"

if [ ! -f "$AGENTS_DIR/core.md" ]; then
    echo "wire-agent-instructions: $AGENTS_DIR/core.md not found - clone mr-x/docs first" >&2
    exit 1
fi

# Claude Code: real file with @ imports (tilde form verified working).
mkdir -p "$HOME/.claude"
if [ -L "$HOME/.claude/CLAUDE.md" ]; then
    rm "$HOME/.claude/CLAUDE.md"   # drop the pre-2026-09-07 symlink
fi
cat > "$HOME/.claude/CLAUDE.md" <<'EOF'
# Global agent instructions

The rules live in `~/docs/agents/`, shared by every agent on this machine and
versioned in the private `mr-x/docs` repo. This file only points at them.

Edit the canon, never this file. If a rule ends up written here, it has been
duplicated and will drift.

@~/docs/agents/core.md
@~/docs/agents/orchestrator.md
EOF
echo "wired: ~/.claude/CLAUDE.md (pointer)"

# Codex and Gemini: no import support, so copy the stub into place.
for slot in "$HOME/.codex/AGENTS.md" "$HOME/.gemini/GEMINI.md"; do
    if [ -d "$(dirname "$slot")" ]; then
        cp "$AGENTS_DIR/stub.md" "$slot"
        echo "wired: $slot (copy of stub.md)"
    else
        echo "skipped: $slot (agent not installed)"
    fi
done

# OpenCode: instructions array, core only. Workers do not need orchestrator.md,
# and the smaller local models degrade when the context is padded with rules
# that do not apply to a one-shot mechanical task.
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
if [ -f "$OPENCODE_CONFIG" ]; then
    python3 - "$OPENCODE_CONFIG" <<'EOF'
import json, sys

path = sys.argv[1]
with open(path) as fh:
    config = json.load(fh)

wanted = ["~/docs/agents/core.md"]
if config.get("instructions") != wanted:
    config["instructions"] = wanted
    with open(path, "w") as fh:
        json.dump(config, fh, indent=2)
    print("wired: ~/.config/opencode/opencode.json (instructions)")
else:
    print("already wired: ~/.config/opencode/opencode.json")
EOF
else
    echo "skipped: $OPENCODE_CONFIG (agent not installed)"
fi
