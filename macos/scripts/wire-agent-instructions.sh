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
# Codex is the declared backup orchestrator (2026-09-08), so it also gets the
# harness pieces Claude has and the canon assumes: the secret-guard PreToolUse
# hook (Codex speaks the same wire format, from ~/.codex/hooks.json) and the
# org-mcp server. Codex silently skips a user hook until its hash is recorded
# under [hooks.state] in config.toml; the hash is not a file digest, so this
# script asks `codex app-server` (hooks/list) for it. chrome-devtools,
# task-master and ask-user need no wiring here: agent-shell injects them into
# every ACP session, Codex included.
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

# Codex harness: guard hook (trusted) + org-mcp.
CODEX_HOME="$HOME/.codex"
if [ -d "$CODEX_HOME" ] && command -v codex >/dev/null 2>&1; then
    GUARD="$HOME/.dotfiles/macos/scripts/secret-guard-hook.sh"
    HOOKS_JSON="$CODEX_HOME/hooks.json"
    python3 - "$HOOKS_JSON" "$GUARD" <<'EOF'
import json, sys, os

path, guard = sys.argv[1], sys.argv[2]
want = {"type": "command", "command": guard, "timeout": 10}
config = {"hooks": {}}
if os.path.exists(path):
    with open(path) as fh:
        config = json.load(fh)
groups = config.setdefault("hooks", {}).setdefault("PreToolUse", [])
present = any(h.get("command") == guard for g in groups for h in g.get("hooks", []))
if present:
    print("already wired: ~/.codex/hooks.json (guard hook)")
else:
    groups.append({"matcher": "Bash|Read", "hooks": [want]})
    with open(path, "w") as fh:
        json.dump(config, fh, indent=2)
        fh.write("\n")
    print("wired: ~/.codex/hooks.json (guard hook)")
EOF

    # Trust it: ask the app-server for the hook's key + current hash, then
    # record them under [hooks.state]. Untrusted hooks are skipped silently.
    HOOK_INFO=$( (printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"wire-agent-instructions","version":"0"}}}' \
        '{"jsonrpc":"2.0","method":"initialized"}' \
        '{"jsonrpc":"2.0","id":2,"method":"hooks/list","params":{}}'; sleep 6) \
        | timeout 30 codex app-server 2>/dev/null \
        | python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    d = json.loads(line)
    if d.get("id") != 2:
        continue
    for cwd in d["result"]["data"]:
        for h in cwd["hooks"]:
            if h["source"] == "user" and h["command"].endswith("guard-hook.sh"):
                print(h["key"], h["currentHash"], h["trustStatus"])
                sys.exit(0)
' )
    if [ -z "$HOOK_INFO" ]; then
        echo "warning: codex app-server did not list the guard hook; trust not recorded" >&2
    else
        python3 - "$CODEX_HOME/config.toml" $HOOK_INFO <<'EOF'
import sys, re

path, key, digest, status = sys.argv[1:5]
with open(path) as fh:
    s = fh.read()
block = f'[hooks.state."{key}"]\ntrusted_hash = "{digest}"\nenabled = true\n'
pat = re.compile(r'\[hooks\.state\."' + re.escape(key) + r'"\]\n(?:[^\[\n][^\n]*\n|\n)*')
m = pat.search(s)
if m and m.group(0).strip() == block.strip():
    print("already trusted: ~/.codex/hooks.json guard hook")
    sys.exit(0)
if m:
    s = s[:m.start()] + block + "\n" + s[m.end():]
elif "[hooks.state]\n" in s:
    i = s.index("[hooks.state]\n") + len("[hooks.state]\n")
    s = s[:i] + "\n" + block + s[i:]
else:
    s = s.rstrip("\n") + "\n\n[hooks.state]\n\n" + block
with open(path, "w") as fh:
    fh.write(s)
print(f"trusted: ~/.codex/hooks.json guard hook (was {status})")
EOF
    fi

    # org-mcp: milestones, todos, notes. Lives in ~/roaming (Syncthing), so the
    # path is the same on every Mac that has a roaming clone.
    ORG_MCP="$HOME/roaming/projects/MCP servers/org-mcp/dist/index.js"
    if [ -f "$ORG_MCP" ]; then
        if codex mcp get org-mcp >/dev/null 2>&1; then
            echo "already wired: codex mcp org-mcp"
        else
            codex mcp add org-mcp -- node "$ORG_MCP" >/dev/null
            echo "wired: codex mcp org-mcp"
        fi
        # "approve" = no per-call prompt, matching how Claude calls it in
        # agent-shell. Also what lets a headless `codex exec` reach it at all.
        python3 - "$CODEX_HOME/config.toml" <<'EOF'
import sys, re
path = sys.argv[1]
with open(path) as fh:
    s = fh.read()
m = re.search(r'\[mcp_servers\.org-mcp\]\n', s)
if not m:
    sys.exit(0)
end = s.find("\n[", m.end())
blk = s[m.end():end] if end > 0 else s[m.end():]
if "default_tools_approval_mode" in blk:
    sys.exit(0)
new = blk.rstrip("\n") + '\ndefault_tools_approval_mode = "approve"\n'
s = s[:m.end()] + new + (s[end:] if end > 0 else "")
with open(path, "w") as fh:
    fh.write(s)
print("wired: codex org-mcp default_tools_approval_mode=approve")
EOF
    else
        echo "skipped: codex org-mcp ($ORG_MCP not found)"
    fi
else
    echo "skipped: codex harness (codex not installed)"
fi
