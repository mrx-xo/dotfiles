# keymap explorer roadmap

The one document for where this whole effort stands and what's left. Two
tracks that end in a single board flash:

- **Track 1 — solidify the hotdox layout** (the reason this project exists):
  decide the "Proposed" layout in `index.html`, then bake it into firmware.
- **Track 2 — live keymap widget**: Phase A shipped; Phase B (live layer
  tracking) needs firmware too.

**Unifying decision (2026-07-24): flash ONCE.** Phase B's raw-HID broadcast
rides along with the new layout in the same `keymap.c` — no point flashing
twice. Everything below is sequenced around that.

---

## Done so far

- `index.html` — self-contained explorer for both boards: hotdox current vs
  proposed (side-by-side view, changes ringed), all layers, hover keycodes;
  creator micro with real VIA layout, encoders, touch pads.
- **Widget Phase A live** (commits `1681fb7` here, `f8797dc` dotfiles):
  chrome-less `&widget` mode, two Hammerspoon webviews on the portrait
  Dell's wallpaper layer, live held-modifier highlighting (green), live
  per-keypress flash (amber, ⌘⌃⇧K toggles), ⌘⌃K hides/shows, screen
  watcher handles undock. Event-driven end to end, ~0% idle CPU.
- PRD v1.2 (`live-keymap-widget-prd.md`) — includes the key-flash addendum
  (press state survives re-renders; mod-tap taps stretched to 140ms min).

---

## Track 1 — solidify the hotdox layout

The "Proposed" side of `index.html` is the working draft. **Constitution
(2026-07-24): alphas/Dvorak and home-row mods never move — that's real
muscle memory. Everything else is up for grabs; comfort over incumbency.**
(The old symbols layer, kept "because scared to change it", died in audit.)

### The proposal, summarized

- **Base**: ✦ Hyper / ◆ Meh on the small mid-thumb keys; SYM gets **two
  activators** (#47 stays a pure `MO(1)` hold — the thumb-reach habit —
  plus new `LT(1)` on left big Space; opposite thumbs unlock the
  tri-layer); #46 mirrors as `MO(2)` Nav; wheel keys deleted
  (`MOUSEKEY_ENABLE = no`, frees ~2KB); dead BL keys → Vol−/Vol+/Play;
  duplicate bottom-left Ctrl → Nav LOCK `TG(2)`; Caps Word on the small
  right thumb; **base arrows #57–60 and ALL base brackets (#20/#21,
  #61/#62) removed** (nav discipline — arrows on Nav only, brackets on
  Sym only). **Walk sign-off 2026-07-27:** corner mod-taps dropped
  (#0/#14 plain Esc/Tab, HRM covers ⌘/⌥); #6/#7 → Prev/Next (full media
  set now on base); #74 → thumb Esc for evil-mode.
  **Daily drivers (decided 2026-07-24)** on the never-used thumb-top keys:
  #64 Agenda ⌘⇧A, #65 Del, #66 Recent ⌘⇧⇥, #67 Scratchpad ⌘⇧Space,
  #72 Layout toggle ⌃Space — one-tap versions of top skhd chords
  (Home/End/PgUp/PgDn stay available on Nav).
- **Symbols (1)**: REDESIGNED 2026-07-24 (v1 failed audit: `=`/`+`/`()`
  duplicated, a lone `[` with no `]`, top row mirroring shift+numbers).
  v2 = bracket stack on left middle+index columns ({ } / ( ) / [ ] by
  row), operator cluster `& = * + |` on right home, `` ` `` and `~` get
  real spots, zero within-layer dups.
- **Nav (2)**: right hand gains a numpad + Del; left-hand arrows/Home/End
  stay put.
- **System (3)**: newly *reachable* via Space+Enter tri-layer — slimmed
  in the walk sign-off to one job: BOOT, EE Clr, Game TG(4), RGB
  controls (media moved to base).
- **Game (4)**: full QWERTY both halves (decided 2026-07-24 — game prompts
  like "M for map" need the right hand too; half-Dvorak chat was typeable in
  neither layout), no mod-taps anywhere (thumb Bksp/Enter overridden to
  plain), `TG(4)` exit on the layer itself, solid red RGB while active.

### Decisions still open (the actual work)

- [x] **Symbol-thumb swap: RESOLVED 2026-07-24 — keep both.** The real
      habit turned out to be the #47 thumb reach (not #69); #47 stays a
      pure SYM hold and left Space adds `LT(1)`. Two activators, zero
      retrain, tri-layer intact.
- [x] **Layer walk: SIGNED OFF 2026-07-27.** All five layers walked;
      proposals 1–5 accepted (plain Esc/Tab corners, Prev/Next on #6/#7,
      #20/#21 blanked, thumb Esc #74, slim System). A blank-slate
      "claude" alternative was built into the explorer, compared
      side-by-side, and declined — proposed converges on the same
      principles while keeping real muscle memory.
- [x] **Tap-hold feel: RESOLVED 2026-07-27 — ship as-is.** Current feel is
      fine; no `TAPPING_TERM` / flow-tap changes ride this flash. Tuning
      stays available as a later firmware-only tweak if HRM ever misfires.
- [x] **skhd migration: DONE 2026-07-28** (dotfiles `0574f96`). Focus/warp
      → ✦/◆ hjkl, displays → ✦/◆ 1–4, float/zoom → ✦ t/f, one-tap
      ✦ e/a/space added; alt-hjkl/1–4/t/f deleted — Meta works in Emacs
      again. All ⌘⇧-chords kept (the board's daily-driver keys send them
      as real keycodes). ✦ G magit pending a focus-emacs-then-magit
      helper script.
- ~~Optional zero-flash trials via VIA~~ **Declined 2026-07-24**: VIA's
  GUI clicking is anti-declarative; everything goes through `keymap.c` and
  rides the one flash. Follow-up **RESOLVED 2026-07-27: drop `VIA_ENABLE`
  entirely.** Frees ~2KB flash, and with no dynamic keymap the EEPROM
  shadowing + 5-layer fit concerns evaporate — the compiled keymap is the
  only keymap. Cost accepted: usevia.app inspection is gone forever.
  Consequence for Phase B: VIA no longer forces `RAW_ENABLE`, set it
  explicitly.

### Firmware changes the layout needs (beyond keycaps)

All confined to `keymaps/mrx/`:

- `EXTRAKEY_ENABLE = yes` (media keys), Caps Word enable,
  `MOUSEKEY_ENABLE = no` (wheel keys deleted; pays the flash-size bill —
  see FLASHING.md size budget)
- `VIA_ENABLE = no` (decided 2026-07-27) + explicit `RAW_ENABLE = yes`
  (Phase B needs raw HID and VIA isn't there to force it on anymore).
  The old `DYNAMIC_KEYMAP_LAYER_COUNT` 4→5 bump is moot — five compiled
  layers, no dynamic keymap.
- Tri-layer (`update_tri_layer_state` in `layer_state_set_user`)
- `rgb_matrix_indicators_user` — solid red while Game is active

### Concerns / gotchas

- **VIA EEPROM shadowing: DEFUSED by dropping `VIA_ENABLE`** (2026-07-27).
  With no dynamic keymap the firmware never reads the old VIA layout out
  of EEPROM — the board comes up on the compiled keymap, period. Still do
  a one-time "Clear EEPROM" (QMK Toolbox) on the transition flash to wipe
  stale VIA data and let eeconfig re-init clean. NOT bootmagic: verified
  2026-07-24 that bootmagic can't fire on this board (no key at matrix
  0,0). Full verified flash runbook: `FLASHING.md`.
- Game layer must stay mod-tap-free (tap-hold delay eats held movement
  keys) — resist the urge to "just add one".

---

## Track 2 — live keymap widget, what's left

Full spec: `live-keymap-widget-prd.md`. Phase A is done; remaining:

### Phase B — live layer tracking (hotdox only)

**SHIPPED 2026-07-27, all three pieces — verified live on the wallpaper**
(hold Sym → widget flips, tri-layer System renders, snaps back on release).
Listener at `~/.dotfiles/macos/scripts/keymap-widget-hid.py` (hidapi via
pip --user), supervision + relay in `keymap-widget.lua`. Promotion landed
2026-07-28: widget and default view render `cur`, which IS the flashed
keymap; the pre-flash layout survives as the explorer's "Pre-flash" view,
change-rings only in side-by-side.

1. **Firmware** (rides the Track 1 flash): `layer_state_set_user` sends
   `[0x4C, highest_layer]` via `raw_hid_send` on every change, plus once in
   `keyboard_post_init_user`. With VIA dropped (2026-07-27), set
   `RAW_ENABLE = yes` explicitly; `raw_hid_receive` is ours now and we
   simply don't define it (broadcast-only).
2. **Host listener**: `~/.dotfiles/macos/scripts/keymap-widget-hid.py`
   (python + `hidapi` only) — opens by VID/PID + usage page `0xFF60`,
   blocking reads, drops frames not tagged `0x4C`, prints `L<n>` lines.
3. **Hammerspoon wiring**: `hs.task` spawns/supervises the listener,
   forwards lines to `__setLayer(n)` on the hotdox webview only; reconnect
   backoff 2s→30s on unplug/sleep; fall back to layer 0 while down; clean
   kill on `hs.reload`.

Items 2–3 can be written and reviewed *before* the flash; they just can't
be end-to-end verified until the firmware broadcasts.

### Known caveats in what's already shipped (Phase A)

- **Key flash vs layers**: flashes match the *displayed* layer's legends,
  so typing through Symbols/Nav mismatches until Phase B auto-switches the
  layer. Known, accepted, self-heals with Phase B.
- Secure input (password fields) freezes modifier/key events — accepted.
- Rare eventtap timeout under heavy system load can drop a burst of
  events; Hammerspoon auto-revives the tap.
- Creator micro layer sync is permanently out of scope (stock firmware);
  its widget follows OS mods only, layers switched by hand.

---

## The endgame, in order

**Status 2026-07-27: steps 1–5 DONE.** `keymap.c` written (all five layers
+ tri-layer + Game RGB + Phase B broadcast), compiled at 26210/28672
(2462 free), flashed, board typing on the new layout. Post-flash
discovery: `keyboard.json` draws the right thumb talls crossed — physical
#75 Enter = outer (never moved), #74 Esc = inner (old Tab key); firmware
already ideal, explorer GEO fixed to draw reality (see FLASHING.md).
**COMPLETE 2026-07-28.** All code/doc aftermath done (pro→cur promotion,
skhd migration, PRD + roadmap) AND all physical steps done: EEPROM
cleared via Space+Enter → EE Clr, right half flashed (Game RGB solid red
both halves), step 6 stress test PASSED (layer tracking, tri-layer,
mod-tap burst, held-mod highlight). Both tracks shipped; only the
parking lot remains.

1. **Layout decision sessions** (Track 1 open items) — tweak the `pro*`
   maps in `index.html` as decisions land; the explorer is the scratchpad.
2. Optional VIA zero-flash trials for the paintable subset.
3. Write the host side of Phase B (listener + hs.task wiring) — reviewable
   before any flash.
4. **Write the new `keymap.c`**: finalized layout + tri-layer + Game RGB +
   the Phase B broadcast hook, plus the `rules.mk`/`config.h` bits.
5. **The one flash** — immediately followed by the EEPROM/VIA reset.
6. Verify with the widget itself: hold each thumb key, watch the wallpaper
   confirm the firmware's layer in real time; 2-minute stress test per the
   PRD success criteria.
7. Aftermath:
   - [x] `index.html`: promoted 2026-07-28 — `cur` is the flashed keymap
         (footer ref `99e020a`), pre-flash kept as the "Pre-flash" view,
         change-rings now mark what the flash changed (side-by-side only).
   - [x] skhd migration to Hyper/Meh binds 2026-07-28 (dotfiles
         `0574f96`) — alt-hjkl freed for Emacs.
   - [x] PRD status + this roadmap updated 2026-07-28.

## Parking lot (noted along the way, no commitments)

- Micro free keys: F15 (agent allow-always) and ⇧F18 (vengeance wake) are
  bound in skhd but absent from the pad; `CUSTOM(7/8/9)` (matrix
  brightness/indicator) unbound — a val column on the RGB layer.
- M2/M3 macros (org-clock in/out) defined in VIA but bound to no key.
- Windows/VENGEANCE layer story (kanata) — separate effort, out of scope.
