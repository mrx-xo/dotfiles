# GAIA Remote — Apollo panel

Web-based TV remote / control panel for the living-room Samsung Q60BD, served from
homelab, used on phones and (eventually) the wall-mounted Kindle Fire HD "APOLLO".
Part of the e-ink/tablet fleet project — see `../ereader-fleet.md`.

Concept: **GAIA** is the brain (homelab); each panel is a node that announces itself
— "**SERVING GAIA · as APOLLO**". Same backend, per-device identity.

## Lead design: `mocks/hub-sun.html`

The current direction = **our ergonomic structure wearing the "Apollo, portable sun"
brass skin.** Don't rebuild the structure to fit a new look; reskin the structure.

**Structure (ours, keep):**
- **Now-playing display** up top (the glance zone) → tap for full playback screen
- A **glance band** (explicit flex spacer) — currently empty w/ a warm glow; candidate
  for a clock / "up next" / ambient art
- **Control cluster** in the thumb zone with an **L / C / R position toggle** (top-right
  segmented control) — moves the whole cluster left/center/right for one-handed use
  either hand, or centered for two hands / wall. Cluster = lyre volume + clean swipe
  pad (gold OK orb, faint arrows, swipe or tap) + Back/Home corners
- **Bottom bar**: Apps + Search (Keyboard)
- **Summonable sheets**: Apps grid, Keyboard (type-to-TV), Playback screen

**Skin (from a concept, keep):** brass on warm black; Cormorant Garamond (serif) +
IBM Plex Mono (engraved labels); one red (#A33327) reserved for power (sunburst icon);
lyre = 7-string volume; gold OK orb as the one "sun" moment (the ornate sundial dial
was tried in `hub-apollo.html` and dropped — too busy). Palette:
`#100D0A` stage · `#16120E` shell · `#B98B3F` brass · `#F2D48A` lit gold ·
`#5C7A6E` verdigris · `#A33327` red · `#EDE4D3` marble. Light mode = marble.

## All mock variants (design history — nothing deleted)
- `obsidian.html` / `signal.html` / `console.html` — the 3 original aesthetic directions
- `hub.html` — centered d-pad hub
- `hub-swipe.html` — big swipe surface
- `hub-thumb.html` — thumb cluster + L/C/R (the ergonomic breakthrough)
- `hub-apollo.html` — the raw "portable sun" concept (centered sundial — rejected layout)
- `hub-sun.html` — **LEAD**: thumb-cluster ergonomics + Apollo skin, clean swipe pad

## Platform capabilities (what to wire up)
Samsung Tizen (via `samsungtvws`, token at `~/tvctl/token.txt` on homelab):
- `send_text` + IME sync → **type-to-search** into the TV (killer feature)
- **DIAL** app-launch: `POST http://TV:8001/api/v2/applications/<id>` (WS run_app is
  locked on 2022 firmware — DIAL is the working door)
- `move_cursor` → trackpad; keys for nav/volume/playback; WoL power-on; running-app query
- App IDs + TV details in `../ereader-fleet.md`. Household apps: Vix, Angel, YouTube,
  Jellyfin, Jellyseerr (Vix/Angel IDs still TBD; Jellyfin = sideload).

## APOLLO (2012 Fire HD Silk) compatibility — HARD-WON, DON'T FORGET
- **No CSS variables, no CSS grid** → hardcode hex colors, use flexbox (`-webkit-box`
  prefixes) + inline-block, `display:none` to hide (not transform).
- **Swipe needs `touchmove` + `preventDefault`** or Silk eats the gesture as a scroll.
  (Broke twice by omitting it.)
- **Emoji glyphs don't render** → use inline SVG icons or text/geometric chars.
- **`input tap`/`input swipe` unsupported on Android 4.0.3** (adb) — only keyevents;
  `am start -a android.intent.action.VIEW -d <url>` launches the browser.
- **Web fonts DO load** on this Silk (Cormorant + Plex Mono via Google Fonts render
  natively — verified on device). So the full skin is faithful even pre-flash.
- Post-flash (LineageOS 14.1) → modern browser, all constraints relax.

## Serving
`gaia_control.py` (Flask, `gaia-control.service` on homelab, port 8092). Mocks at
`/m/<name>` (reads `mocks/<name>.html`). Live remote at `/`. This repo copy is the
version-controlled source of truth; homelab `~/tvctl/` is the deployed copy.

## Still open (the "few changes")
- The empty glance band: fill (clock / up-next / sun art) or leave calm — undecided
- App tiles are plain brass letters — want real logos
- Nothing is wired to the TV yet (these are visual+interaction mockups)
- Wire: DIAL app-launch, keys, type-to-search, WoL power, now-playing query
- Absolute-volume slider needs verifying (UPnP/SmartThings) vs the stepped lyre
- **`apollo.jpg` → APOLLO lockscreen (POST-FLASH task):** locked on stock FireOS
  (Amazon lockscreen `com.amazon.dcp`, no root, Android 4.0.3 has no custom-lockscreen
  API). After the LineageOS flash: set it as the lockscreen wallpaper, and/or use it as
  the Fully Kiosk idle/ambient screen (the nicer "APOLLO shows Apollo when idle" option).
  Image is in this dir + served at `/img/apollo.jpg`.
