# Layout version ledger

One integer per **flashed** layout per board, forever incrementing. "What
version is on the board?" is always answered here and in the explorer's
eyebrow/footer. Boards version independently — hotdox first, Creator Micro
at the end.

The next layout is carried as a **draft** (`vN draft`), built up in numbered
increments (`d1`, `d2`, …) shown in the explorer's proposal changelog. A flash
promotes the draft: it gets a keymap.c commit + flash date here, the old
current is marked retired, and drafting restarts at `d1` for `vN+1`. Both
boards run the ritual (Micro since v3; explorer grew its own version picker
+ side-by-side on 2026-07-30).

## Ledger — hotdox76v2

### v1 — retired 2026-07-27
- keymap.c commit: `8eb6039`
- The original layout, kept in the explorer as "Pre-flash" for the record.
- Known problems: 3 dead keys (backlight codes on an RGB board), ~10 duplicate
  base-layer keys, layer 3 unreachable, nav layer right hand empty, no
  Hyper/Meh, media keys impossible (EXTRAKEY disabled).

### v2 — retired 2026-07-29
- keymap.c commit: `99e020a` · flashed 2026-07-27, retired by the v3 flash
- Walk proposals 1–5, signed off on the 2026-07-27 walk:
  - ✦ Hyper / ◆ Meh on the small mid-thumb keys; skhd migrated under them
  - Symbols v2 audited redesign (bracket stack left, operators right home)
  - Two-activator Sym (#47 + left Space LT(1)) and Nav (#46 + Enter LT(2))
  - Dead BL keys → Vol−/Vol+/Play; Prev/Next on #6/#7 (EXTRAKEY on)
  - Nav discipline: base arrows and all four bracket keys removed
  - Daily drivers on thumbs: Agenda · Del · Recent · Scratch · Layout
  - Caps WORD, Nav LOCK, thumb Esc (#74); corner mod-taps dropped
  - System layer with reachable BOOT, EE Clr, TG(4) Game; Game = full QWERTY
- Tap-hold ships as-is; VIA_ENABLE dropped; MOUSEKEY_ENABLE off (~2KB freed).

### v3 — on board, flashed 2026-07-29
- keymap.c commit: `c6b22e1` · 26210/28672 bytes (91%), 2462 free
- Promoted increments (drafted 2026-07-28/29):
  - **d1** — criss-cross Hyper/Meh: #20 → `KC_MEH`, #21 → `KC_HYPR` on the
    dead ex-bracket keys — both mods on both hands, opposite-hand grips.
  - **d2** — home row completes (trial): #33 I → `MEH_T(KC_I)`, #34 D →
    `HYPR_T(KC_D)`. Delete if "if"/"it" misfires bite.
  - **d3** — tab switching goes firmware: Nav #29 → Tab◀ `LAG(KC_LEFT)`,
    #32 → Tab▶ `LAG(KC_RGHT)`; arrows drop to #41–44, #30/#31 freed.
    skhd ✦,/✦. Hammerspoon binds retired at the flash.
  - **d4** — Tab comes back, twice: #58 + #59 (dead ex-arrow keys) →
    `KC_TAB`. ⌘Tab = ⌘ on E (HRM) + tap #59, opposite hands.
- Right-half reflash not needed: no RGB/OLED behavior changed vs v2.

### v4 — draft
- Drafted 2026-07-30 onward:
  - **d1** — **Emacs layer** (new layer 5, `_EMACS`). Reached by holding `#57`
    (left-inner ex-arrow dead key, empty since the v2 nav-discipline cull) as
    `MO(5)`; right hand taps the command — the "hold opposite the target"
    grip Sym/Nav already use. Eight keys, each a one-tap `HYPR(x)` chord: home
    row `✦i` imenu · `✦b` buffers · `✦g` magit · `✦s` search · `✦r` recent;
    top row `✦p` project · `✦o` window · `✦d` dired. Curated to Hyper letters
    skhd leaves alone (`e a f h j k l t` + space + 1–4 are the yabai binds),
    so every chord falls through to Emacs. Measured cost **+168 bytes** by an
    empty-layer compile diff (26210 → 26378; 2294 free). Emacs side is bound
    and live today (`emacs.org` Hyper block) — works by holding Hyper on the
    home row even before the flash bakes in the one-tap layer.

## Ledger — Creator Micro (work_louder/micro)

### v1 — retired 2026-07-30
- VIA dynamic keymap, configured live in the VIA app; snapshot preserved as
  `creator_micro_v1.layout.json` (now historical, no longer the source of
  truth). Ran on Work Louder's stock VIA firmware.
- 4 layers cycled by the bottom-right touch pad: media/hotkeys → Spotify →
  monitors → RGB. Encoders: scroll wheel + ctrl-volume knob.

### v2 — retired 2026-07-30
- keymap.c commit: `529c4996ae` (qmk_firmware, `keymaps/mrx`) · flashed
  2026-07-30, retired by the v3 flash the same day
- **Keystroke-identical to v1** — the change is *where the layout lives*:
  baked into the compiled keymap instead of EEPROM. Bootmagic (hold top-left
  encoder while plugging in) wipes EEPROM on every bootloader entry, so the
  compiled fallback must be the real layout; flashes are now harmless.
- VIA macros became firmware: screenshot → plain `LSG(4)`, Spotify pair →
  `SEND_STRING` custom keycodes. Editable only in keymap.c from here on;
  VIA stays enabled for live tweaks (fold keepers back into keymap.c).
- `CUSTOM(0..6)` (per-key RGB controls) reinstated as `QK_KB_0..6` handlers —
  QMK #24322 had deleted Work Louder's implementations with the via keymaps.
- New: raw-HID layer broadcast (`[0x4C, layer]`, same frame as the hotdox) —
  the wallpaper widget now tracks the Micro's live layer too. Size bill paid
  by dropping Space Cadet / Grave Esc / Magic (provably unused in v1).

### v3 — retired 2026-07-30
- keymap.c commit: `f1df23a` · flashed 2026-07-30, retired by the v4 flash
  the same day · 28240/28672 bytes (98%), 432 free
- Promoted increments (drafted 2026-07-30):
  - **d1** — **Monitors go declarative**: layer 2 keys become full desk
    states, idempotent — press = the desk looks like the icon. Presets:
    `mac` F18 · `game` F17 · `split` ⌥F17 (new binding) = 3 mac + 4 VENGEANCE
    · `work` ⇧F17 (becomes a full state: 3→mac too). Flips demoted to
    secondary keys (F19/⇧F19). `game` absorbs summon (walk finding, same
    day): F17 → `vengeance-wake.sh game` — awake = instant switch, asleep =
    WoL then switch; a separate summon key was a transition dressed as a
    state. Wordless caps: OS logos + desk-state icons.
  - **d2** — **#11/#12 pinned pad-wide**: #11 = whisper (⌥Space →
    SuperWhisper, new key), #12 = shot — defined on base, `KC_TRNS` on every
    other layer (the trick the encoders already use). Spotify launchers move
    up to row 2 (#7/#8). First transparent keys on the pad; explorer renders
    them ghosted with the base action.
- Shipped alongside the flash: `monitor-mode.sh` split + full-state work +
  idempotent skip (no reconnect dance when already in state), skhd F17 →
  `vengeance-wake.sh game` · ⌥F17 → split · ⇧F18 summon binding retired,
  `vengeance-wake.sh` fast path (SSH answers → straight to handover).

### v4 — on board, flashed 2026-07-30
- keymap.c commit: `cfe66ba` · 28240/28672 bytes (98%), 432 free (keycode
  swap — zero size cost)
- Promoted increments (drafted 2026-07-30):
  - **d1** — **rsplit joins the presets**: VENGEANCE takes the *center*,
    right stays mac (3 win · 4 mac) — split mirrored, on the ⌥ row (⌥F18;
    ⌥F17/⌥F18 = the half-splits). Takes work's cap (#3); work slides right
    to #4 keeping ⇧F17 — keycode travels with the meaning, skhd's work
    binding untouched. Wake-routed like game: pc on glass implies awake.
- Shipped alongside the flash: `monitor-mode.sh` rsplit preset +
  window-layout save/restore across switches (snapshot by display UUID
  before a mac→away flip, windows moved home after reconnect),
  `vengeance-wake.sh` generalized to hand over any preset, skhd ⌥F18 +
  ⌃⌥R → `vengeance-wake.sh rsplit`.

### v5 — draft
- No increments yet — identical to v4. First change becomes d1.

## Flash-day checklist

1. Flash, stress-test, note the keymap.c commit.
2. Update `LAYOUTS` in `index.html`: pro → current (commit, date), current →
   retired, append new draft entry (v+1); reset `PRO_LOG` to empty/d1.
3. Archive the promoted draft's increments into this file under its version.
4. Commit both files together.
