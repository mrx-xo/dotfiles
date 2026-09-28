# Handoff: MrX2 agent-shell 0.78.2 upgrade

Date: 2026-09-24
Status: Built, restarted, and verified on MrX2. MrX prod Emacs and the Emacs
sandbox were not changed or restarted during this execution.
Plan: `macos/docs/superpowers/plans/2026-09-23-agent-shell-078-upgrade.md`

## Target state

- Target machine: MrX2 only.
- Dotfiles checkout: `~/.dotfiles`, local `main`.
- Nothing from this upgrade was pushed to the shared dotfiles remote.
- The running MrX2 daemon has agent-shell 0.78.2 loaded.

## Commits

- `ee0ee1b138ec60414c006e9415150dedbd6e48f9` —
  `emacs(agent-shell): chat mode off, persistent prompt stays on`
- `6f09088a323dd0e9ce77289f8d4c7501ceead76f` —
  `syzygy: guard queued and steered prompts too`
- `3faae5954217735adab2d62ca8e4dedc0b7a3bef` —
  `syzygy(live): only phone chunks arm the submit guard`
- `19dca8bd816094eeff4e35a847c72303c14bd3f7` —
  `syzygy: pin acp-multiplex 9577ffd (steer synth, fake-phone scripts)`
- `124224e` —
  `emacs(agent-shell): preserve busy-route integrations`

The final commit preserves attached references and local slash commands on
0.78's busy-submit route, and extends both SYZYGY guards to direct queue and
steer commands.

## Installed source and build state

- agent-shell source: `4cbcd12d84a2eed03a842944e9a9494f2852ac46`
- shell-maker source: `f448a74a8eded23aa42f8d60a41c5d8d3a183d07`
- acp source: `242cef63d76cc1073485847f67a21f6d8406d158`
- Elpaca rebuild: 45 fresh agent-shell `.elc` files and both Antigravity
  files present.
- acp-multiplex source and binary: `9577ffd26651ac2d144d61729ac0a1680aa02e4c`;
  rebuilt on MrX2 at 2026-09-24 09:46 CDT.

## Verification

- MrX2 batch load: `agent_shell_version=0.78.2`,
  `chat_mode_enabled=nil`, `persistent_prompt_enabled=t`.
- Focused SYZYGY ERT: 7/7 passed, including locked and unlocked busy-submit
  routing plus all three live guard cases.
- Focused agent-shell refs ERT: 7/7 passed.
- Reviewer regression ERT: 5/5 passed for busy-route refs, local commands,
  direct queue guards, and direct steer guards.
- acp-multiplex: `go test ./...` passed.
- Full config ERT: 167/171 passed. The tangle synchronization test passed.
  Four failures remain outside this upgrade's changed files:
  - two Mermaid export tests require `pandoc`, which is absent on MrX2;
  - one Mermaid header test requires missing
    `~/.emacs.d/etc/agent-recall-transcript.js`;
  - `config-test-no-stale-elc` reports stale Magit Section bytecode.

## Live integration status

Marcos approved the MrX2 main-daemon restart on 2026-09-24. Startup took about
46 seconds, exceeding the restart helper's 30-second readiness window; the
daemon continued starting successfully, and the saved session was then
restored. One extra blank startup frame was removed. Live checks report
agent-shell 0.78.2, chat mode nil, persistent prompt t, and the restored
`Claude Agent @ MrX2` buffer ready and visible.

The plan's Task 4 sandbox drill was not rerun. Marcos explicitly changed the
scope to MrX2 main Emacs and said not to touch the sandbox. The upgraded build
was not mixed into the old running daemon before the approved restart.

The plan carries these already-verified sandbox results from 2026-09-23:

- a fake phone prompt rendered above the persistent prompt without a
  `No live prompt to render above` error;
- desktop steering interrupted Claude and acp-multiplex forwarded a
  `[steer] ...` user chunk to secondaries;
- advised arglists, subscribed event names, and configured upstream symbols
  remained compatible.

Marcos's check is the remaining live integration gate: phone turn, resync lock
during a busy turn, and desktop steering.

## Rollback

- Revert the five dotfiles commits above on MrX2.
- Restore the MrX2 Elpaca source checkouts to:
  - agent-shell `dcf8688d53a72c7867b47793485877fc539811ab`
  - shell-maker `e7c11e029f3fb54f2c04803d3833e0ccaff4ed3e`
  - acp `7d5c16ebcf2af86aa0f14ad9ae0ce45df4e8c8a5`
- Rebuild the three Elpaca packages, then restart only with explicit approval.
- For acp-multiplex, restore `ACP_MULTIPLEX_COMMIT` to `39e79c8` and rerun
  `macos/syzygy/build-acp-tools.sh` on MrX2.
- If only the persistent prompt misbehaves after promotion, evaluate
  `(setopt agent-shell-persistent-prompt-enabled nil)` in the daemon; this
  does not require a restart.

Next: check the restored `Claude Agent @ MrX2` frame.
