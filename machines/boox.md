# boox — BOOX Tab Ultra C (e-ink Android tablet)

> 10.3" color e-ink tablet, Android 11, Snapdragon 662, serial `B79B7A06`,
> firmware `D60_SMT_V02_2022_0309`. Full Android with a weird screen — treated
> as a fleet box, driven from MrX over adb/ssh. **Not rooted, never rooting**
> (EDL flash is the only path and it can hard-brick). Plan/journey doc:
> `docs/tab-ultra-c-shit.md`.

## Network / access

- LAN `192.168.1.107` (DHCP — static lease still TODO; things break if it drifts)
- **`ssh boox`** (= alias `shb`) → Termux sshd, port 8022, key `id_rsa`, user ignored
  - sshd does NOT autostart; after a reboot run `sshd` in Termux (Termux:Boot TODO)
- **adb**: USB + Wi-Fi (`adb connect 192.168.1.107:5555`). Wi-Fi adb dies on tablet
  reboot — replug USB once and `adb tcpip 5555` to re-arm
- **Mirror**: `boox` alias / `Cmd+Shift+B` → `macos/scripts/boox-mirror.sh`
  (USB-first, Wi-Fi fallback). NEVER bare `scrcpy`: the Qualcomm HW encoder fails
  with `MediaCodec 0xfffffff4`; the script forces `c2.android.avc.encoder`

## Gotchas (each cost real debugging)

- **Firmware auto-freezes third-party apps** (`enabled=3`), including re-freezing
  them later — symptom: "Activity class does not exist". Fix: `pm enable --user 0
  <pkg>`. Termux/Syncthing/F-Droid are user-whitelisted in BOOX freeze settings.
- **Deep sleep** ("Press power button to wake") once killed everything; after the
  freeze-whitelist the syncthing daemon now survives it. Screen-off is safe.
  Software wake (`input keyevent`) can't exit deep sleep — physical button only.
- Launching Termux via `am start` while the screen is off → "background uid"
  service crash and a blank terminal. Wake the screen first.
- Termux F-Droid build is **not debuggable** — no `run-as`; drive it via sshd or
  keystroke injection (`input text`, %s = space; verify focus with
  `dumpsys window | grep mCurrentFocus` first).
- `adb forward` false-positive: `nc -z localhost <port>` succeeds even with no
  device listener. Probe the Wi-Fi IP instead.
- First `adb exec-out screencap -p` after boot prepends a junk line
  ("capture from screenshot!") — run it twice.
- e-ink ≠ OLED: no burn-in exists; static images are free.

## Debloat (batch 1, 2026-07-29 — `pm uninstall -k --user 0`, factory reset reverts)

Removed: dict, mail, clock, igetshop, musicplayer, easytransfer, aiassistant,
voicerecorder, appmarket, calculator, production.test, ksync
Kept on purpose: kreader (until KOReader), android.note (pen latency king),
kime/latinime (keyboards), onyxotaservice (OTA), floatingbutton, gallery,
tscalibration (stylus calibration)

## Installed (sideloaded via adb, all from F-Droid repo)

- **F-Droid** (store), **Termux 1022** (+ openssh, git, emacs 30.2),
  **Syncthing-Fork** (`com.github.catfriend1.syncthingfork`)
- **Olauncher** (`app.olauncher`) — home launcher, Light theme (set via
  `cmd package set-home-activity app.olauncher/.MainActivity`). Replaces ONYX
  ContentBrowser. Home-screen app slots assigned on-device.
- **KOReader** (`org.koreader.launcher`, GitHub arm64 build — not on F-Droid)
- **Termux:Boot** (`com.termux.boot`) → `~/.termux/boot/start-sshd.sh` runs `sshd`
  on boot. Install needed Play-Protect bypass:
  `settings put global package_verifier_enable 0` + tap through "Unsafe app blocked".
- Termux is deviceidle-whitelisted; Syncthing has MANAGE_EXTERNAL_STORAGE;
  olauncher + termux-boot deviceidle-whitelisted too

## Syncthing (paired 2026-07-30)

- Device `H3YAXLD-5JQO4IG-MSFYYW2-3XJPQRZ-NLQ52HC-EGNK5RK-QIEHU74-IMYTQQO`
  ("boox" on MrX); MrX is `LT5L6TJ-…-ASQKCAG`, static addr `tcp://192.168.1.107:22000`
- Folder `roaming-all` → `/storage/emulated/0/roaming` (sendreceive)
- Pairing was done by exporting the app config to
  `/sdcard/backups/syncthing/config.zip`, patching `config.xml`, re-importing via
  the app UI — notification-accept flow never appears on this firmware
- `.stignore` on the tablet (tablet-side only; code is read-only reference there):
  ```
  (?d).git
  (?d)node_modules
  (?d).pnpm-store
  (?d)__pycache__
  (?d).venv
  (?d).next
  (?d)dist
  (?d).elpaca
  (?d)eln-cache
  ```
- Known quirk: Mac-side completion % for boox never reaches 100 (it can't see
  tablet ignores) — judge sync state from the tablet app, not MrX's GUI

## Synced state (2026-07-30)

26.8k files / 3.5 GB in /sdcard/roaming: all project/code source (read-only
reference), notes, agenda. Junk purged post-sync.

## TODO

- [ ] Static DHCP lease for `192.168.1.107`
- [x] Olauncher home-screen slots: Termux / KOReader / Syncthing-Fork / Files
- [x] Whitelisted Olauncher in BOOX freeze settings — verified it stays enabled
      5+ min (was freezing to `enabled=3` and reverting home to ONYX before).
      If home ever reverts again: `pm enable --user 0 app.olauncher` +
      `cmd package set-home-activity app.olauncher/.MainActivity`.

## Drawing / BOOX Notes (the native pen app)

- `com.onyx.android.note` is the best pen-latency drawing app but has **NO
  launcher activity** — it's embedded in the ONYX ContentBrowser. It appears in
  NO app picker (Olauncher, NaviBall "Open an app", nothing). Kept from debloat.
- Direct launch works: `am start -n com.onyx.android.note/.note.ui.CreateQuickNoteActivity`
  (→ ScribbleActivity, the canvas). Saved as `~/.shortcuts/Draw` in Termux.
- **One-tap on device = the NaviBall floating ball → Button 4 = "Notes"** (a
  native NaviBall *action*, page 2/3 of the button-action list — NOT the "Open an
  app" list). Configured via `am start -n com.onyx.floatingbutton/.FloatButtonSettingActivity`.
- **SOLVED via Lawnchair + widget** (community-verified: lopespm.com minimalist
  BOOX guide). The ONLY way to reach native Notes from a custom launcher is the
  ContentBrowser **`NoteGridWidgetProvider`** widget — and that needs a launcher
  that HOSTS widgets. Olauncher AND KISS are both widget-less minimal launchers,
  so neither can do it (wasted hours proving this the hard way).
- **Lawnchair 12.1.0-alpha.4** (GitHub, not F-Droid; v14/v15 betas may reject on
  Android 11) installed + set as home. Supports widgets. Home activity
  `app.lawnchair/.LawnchairLauncher`. Shows the system wallpaper (scribble art
  already set), so no bland default.
- One-tap Notes = long-press Lawnchair home → Widgets → ContentBrowser → Notes
  (NoteGrid) widget → drag to home. Manual drag only (widget bind can't be done
  over adb).
- Still-installed launchers (fallback, non-destructive): Olauncher, KISS.
  Extra chase apps (can uninstall): Termux:Widget, Activity Launcher.
- Root cause of ALL launcher freezes this session: BOOX global auto-freeze;
  user disabled it 2026-07-31, verified apps stop re-freezing.
- [ ] Sleep/standby screen wallpaper (scribble art)
- [x] Termux:Boot → sshd autostart (start-sshd.sh)
- [x] Launcher swap (Olauncher, Light theme) + KOReader installed
- [x] Termux styling + e-ink init.el — `boox/` section, deploy with `boox/deploy.sh`
- [ ] Wallpaper also as sleep/standby screen (BOOX picker:
      `am start -n com.onyx/com.onyx.common.screen.ui.WallpaperActivity`)
