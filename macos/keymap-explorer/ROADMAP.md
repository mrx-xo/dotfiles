# keymap explorer roadmap

Status: active. Scope: the Keebio Iris SE layout, the KOMAX macro pad
page, the explorer, and the wallpaper widget. Owner:
`macos/keymap-explorer/`. KOMAX's behaviour (the desk grammar) is owned by
`docs/active/plans/2026-10-21-komax-desk-grammar.md`.

The hotdox76v2 / Creator Micro roadmap this replaced is in git history up to
`c39eb8b`.

## Done

- **Practice view implemented 2026-10-01**: ten-command leader recall, exact
  current Iris/Dvorak geometry, hints, accuracy/streaks, weighted review,
  searchable/prefix decks, Gruvbox/light/Midnight themes, local progress.
  Effective Emacs leader catalog exported by `practice.sh`; operating and
  recovery instructions live in [README.md](README.md#practice).

## Practice follow-ups

- Native Emacs capture for Hyper/control chords and mode-specific bindings.
  The browser version intentionally trains printable SPC leader sequences.
- Optional ordinary typing rounds from the original typing-practice project.
  Current rounds focus on recalling the user's Emacs commands.

## Earlier keyboard milestones

The older milestones below retain firmware/widget context. Consult
[VERSIONS.md](VERSIONS.md) for the current flashed-versus-draft status.

- **v1 flashed** 2026-09-28 (see VERSIONS.md); the explorer's `cur` maps
  match `keymaps/mrx/keymap.c`.
- **Explorer is Iris-only**: current v1 vs factory, side by side, knob
  legends, key numbering.
- **Wallpaper widget back on** 2026-09-28: one webview for the Iris on the
  portrait Dell, held-mod highlight, per-keypress flash.

## Next

1. **Iris v3 and KOMAX v1 together** (planned 2026-10-22). Iris v3 needs:
   v3 written into `keymap.c` with `MOUSEKEY_ENABLE` and
   `COMBO_ENABLE`, a build, then both halves flashed. Done earlier: v2 is
   flashed and verified on both halves, and committed as `aa41906e08`.
2. **KOMAX v1 onto the pad** (flash-day plan
   `docs/active/plans/2026-10-22-keyboard-flash-day.md`, Task 7): firmware
   built from Keychron's fork, flash per FLASHING.md, then promote v1 in
   `VERSIONS.md` and in the KOMAX `cur0` data. Fn-key question settled
   2026-10-22: NEMESIS takes it; the Fn layer hides behind knob press + Enter.
3. **Port the Emacs layer.** It was drafted for the hotdox (v4 d1, git
   `8457210`): hold a key, the other hand taps a `HYPR(x)` chord for imenu,
   buffers, magit, search, recent, project, window, dired. The Emacs side
   (`H-` bindings in `emacs.org`) already exists.
