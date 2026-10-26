# keymap explorer roadmap

Status: active, reconciled 2026-10-25. Scope: Iris SE, KOMAX, the explorer,
practice and wallpaper widget. Owner: `macos/keymap-explorer/`.
Operation and design constraints: [README.md](README.md).
Firmware identity and physical acceptance details: [VERSIONS.md](VERSIONS.md).

## Done

- Iris v3 on both halves and KOMAX v1 on the pad, flashed 2026-10-22.
  The Emacs layer is in Iris v3; it is no longer an unimplemented port.
- Night-light commands bench-verified on both boards, including KOMAX cable
  and dongle, repeated off, typing while dark, and restoration. Iris power-cycle
  restoration was recorded too. These are historical checks, not a fresh test.
- Practice view implemented 2026-10-01: leader recall, hints, accuracy/streaks,
  weighted review, searchable decks, themes and local progress.
- Wallpaper widgets and host dictation bindings implemented. Physical dictation
  start/stop acceptance is still open.

## Remaining work

1. Complete the remaining Iris v3 and KOMAX v1 physical acceptance lists in
   [VERSIONS.md](VERSIONS.md). Record evidence there rather than resetting
   flashed versions to drafts. Record hardware identity from device-reported
   bytes when verifying the exact revision, rather than inferring it from labels.
2. Exercise both “good night” and “good morning” with both keyboards present;
   prior voice evidence without the Iris does not close this check. Verify
   KOMAX restoration after a longer idle/wake cycle and actual dictation
   start/stop on both hosts. [README.md](README.md) owns commands and recovery.
3. Implement Iris v4 Shot · Copy after configuring the CleanShot host shortcut;
   firmware, flashing and capture/paste acceptance remain pending. The exact
   draft and prerequisites live in [VERSIONS.md](VERSIONS.md#v4-draft-not-flashed).
4. Practice: native Emacs capture for Hyper/control and mode-specific bindings;
   optional ordinary typing rounds. The browser trains printable SPC sequences.
5. Desk grammar: contextual actions follow the machine currently showing
   ROMULUS. A general remote scheduled-task lane remains future scope; the
   deployed dictation task is one specific action. Preserve the documented
   armed-set routing contract and use fixed, allowlisted task names.

Earlier hotdox76v2 / Creator Micro plans remain in Git history through `c39eb8b`.
The superseded October desk/flash recipes are preserved in private `~/docs`
commit `de6641f`; current operation lives here and in the rig runbook.
