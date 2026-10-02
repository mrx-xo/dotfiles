# keymap explorer roadmap

Status: active. Scope: the Keebio Iris SE layout, the explorer, and the
wallpaper widget. Owner: `macos/keymap-explorer/`.

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

1. **Flash the v2 draft (layer broadcast)** so the widget follows layers.
   Already built; flash both halves per FLASHING.md. Then confirm with:

   ```bash
   /opt/homebrew/bin/python3 ~/.dotfiles/macos/scripts/keymap-widget-hid.py
   ```

   It should print `L0` at once and `L1`/`L2` as you hold Sym and Nav.
2. **Commit the Iris keymap** in `~/qmk_firmware` so the ledger can cite a
   commit hash like the old boards did.
3. **Port the Emacs layer.** It was drafted for the hotdox (v4 d1, git
   `8457210`): hold a key, the other hand taps a `HYPR(x)` chord for imenu,
   buffers, magit, search, recent, project, window, dired. The Emacs side
   (`H-` bindings in `emacs.org`) already exists.
