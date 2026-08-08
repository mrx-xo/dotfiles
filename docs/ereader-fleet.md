# E-Reader / Tablet Fleet

Five old e-readers and tablets salvaged from around the house on 2026-08-07.
The plan: turn them into **network dashboards and remotes** — e-ink for always-on
status displays, the color Fire tablets for touchscreen control panels.

Inventory entries (serials, MACs, firmware) live in
`~/roaming/notes/mr-x-inventory-mdox.org` under *Phones / Tablets*. This doc is the
**what-to-do-with-them** plan.

## The prime directive

**Never tap "Update Your Kindle" / "Update Your Nook" on any of these.** Old
firmware is exactly what makes them jailbreakable. A firmware update is the one
move that can permanently close the door.

## The fleet at a glance

| Codename | Device | Screen | Role |
|----------|--------|--------|------|
| MINERVA   | Nook Simple Touch (BNRV300, 2011) | 6" e-ink | e-ink dashboard / macro-pad |
| HEPHAESTUS | Kindle Keyboard 3G (2010) | 6" e-ink + keys | e-ink dashboard / macro pad |
| HADES    | Kindle Fire 1st gen (2011) | 7" LCD | guinea pig (flash-test first) |
| APOLLO   | Kindle Fire HD 7 (2012) | 7" LCD | primary touchscreen control panel |
| ARTEMIS  | Kindle Fire HD 7 (2012) | 7" LCD | second control panel (twin of APOLLO) |

Naming: Horizon Zero Dawn subfunctions. **homelab is GAIA** (the master AI); the
fleet are its subordinate function-terminals — which is literally the architecture
(one brain, many dumb displays). APOLLO/ARTEMIS are twins in myth *and* both real
Horizon subfunctions, landing on the two twin Fire HDs. Rename freely — just handles.

## Why these, not e-waste

Every screen still displayed content when found, which means the panels are healthy
(the main thing that dies on these). The batteries sat dead for years, so first
charge is slow — leave each on micro-USB for an hour before judging it.

Do **not** strip them for parts: an e-ink panel is near-useless without its own
driver board (proprietary connector), and the Fire LCDs aren't worth harvesting.
The value is the whole working device.

## The control-plane idea

All the smarts live on **homelab**. The devices stay dumb:

```
tap on tablet / key on Kindle
        │  HTTP
        ▼
small endpoint on homelab (Flask, ~30 lines)
        │
        ├── samsungtvws  → Samsung TV (keys, app launch, text)
        ├── Jellyfin API → pause / play
        └── (future) lights API
```

Reach everything over the **tailscale IP**, not the LAN hostname — launchd/services
on homelab have been denied LAN access before ("no route to host"); tailnet just
works. (Same gotcha the media-upload watcher hit.)

## Per-device plan

### MINERVA — Nook Simple Touch
- **Root:** NookManager bootable SD card. No exploit games — it's Android 2.1
  underneath and roots from the card. Easiest jailbreak of the fleet.
- **Then:** tiny Android box with an e-ink screen. Dashboard, SSH terminal,
  button-grid control page. E-ink refresh ~0.5s: great for toggles, bad for
  drag/scrub.

### HEPHAESTUS — Kindle Keyboard 3G
- **Jailbreak:** firmware 3.4.2 is well documented; this is *the* classic
  kindle-dash device.
- **Deregister first** (currently on Sergio's Amazon account).
- **Two roles to pick from:**
  1. Always-on e-ink dashboard — homelab renders a PNG (org agenda from `~/roaming`,
     weather, server stats) on a cron; the Kindle fetches it as a screensaver.
     Battery lasts weeks.
  2. Physical macro pad — jailbroken, bind the 40 keys to scripts (press J →
     curl Jellyfin pause). Bedside "pause movie / kill lights" brick.

### HADES — Kindle Fire 1st gen
- **Guinea pig.** Weakest device (512MB RAM). Sideloading is already enabled.
- Practice the flash/root workflow here before risking APOLLO/ARTEMIS.
- **Deregister first** (Yvette's account).

### APOLLO & ARTEMIS — Kindle Fire HD 7 (2012, "tate")
- The 2012 Fire HD 7 ("tate") is one of the best-supported old Amazon tablets.
- **Options:** flash LineageOS/CM11 for a clean Android, **or** just sideload a
  kiosk browser pointed at the homelab control page.
- Color touchscreen = no e-ink latency → **the real remotes** of the fleet.
- Wall-mount one per room with a permanent USB cable = proper home control panels.
- **Confirm model before flashing** (wrong ROM = brick risk): check Settings >
  Device > About says "Kindle Fire HD" not just "Kindle Fire".
- **Deregister both** (Sergio's account).

## Target: the Samsung TV

- **Samsung Q60BD 85"** (Tizen, 2022) at `192.168.1.153`, Wi-Fi MAC
  `A0:D7:F3:7F:C6:04`. WebSocket remote API on port **8002**.
- Library: `samsungtvws`, installed in a venv at `~/tvctl` on homelab.
- **Can do:** every remote key, launch apps by ID, type text into focused fields,
  open URLs, query state (on/off, current app).
- **Can't do:** script *inside* an app ("play S2E4") — you're a fast remote, not an
  app API. Inside apps it's still arrow keys + enter, just automated.
- **Power-on = Wake-on-LAN** to the TV's Wi-Fi MAC (API is dead when TV is off).
- **Pairing:** DONE 2026-08-07. Set Access Notification to "First Time Only" under
  Settings > Connection > External Device Manager > Device Connect Manager, then
  accepted the popup. Token saved at `~/tvctl/token.txt` on homelab — won't re-prompt.
- **App launch gotcha:** the WebSocket `run_app` (launch-by-ID) is LOCKED DOWN on
  2022+ Tizen — it returns success and silently does nothing. The working door is
  **DIAL**: `POST http://192.168.1.153:8001/api/v2/applications/<app_id>`. Keys,
  volume, and nav still go over the WebSocket fine.
- **Confirmed app IDs:** Netflix 3201907018807 · YouTube 111299001912 ·
  Prime Video 3201910019365 · Disney+ 3201901017640 · HBO Max 3201601007230 ·
  Spotify 3201606009684 · Apple TV 3201807016597
- **Dev mode:** already ON (sdb port 26101 open) — a fallback launch path if DIAL
  ever breaks, not currently needed.
- **Apps the household actually uses (TODO — add buttons):** Vix, Angel, YouTube
  (done), Jellyfin. Vix + Angel just need their Tizen app IDs looked up, then a
  DIAL button each. **Jellyfin is different** — not in the Samsung store; it's a
  sideload via developer mode (dev mode already on, so feasible as its own task).

## The control page (SHIPPED 2026-08-07)

A web remote runs on homelab, so any browser is a TV remote — no Kindle needed yet.

- **URL:** `http://192.168.1.143:8092` (LAN) or `http://100.80.97.50:8092` (tailnet)
- **Service:** `gaia-control.service` (systemd, enabled — survives reboot).
  App: `~/tvctl/gaia_control.py` on homelab, Flask in the `~/tvctl` venv.
  Manage with `sudo systemctl {status,restart} gaia-control`.
- **What it does:** power/wake/mute, D-pad + OK, back/home/menu, volume, playback,
  and app-launch buttons (via DIAL). Keys use the WebSocket; apps use DIAL.
- **Source of truth:** lives only on homelab right now. TODO: copy into the dotfiles
  repo so it's version-controlled.
- **This is the control plane** — the Fire tablets (APOLLO/ARTEMIS) will just run a
  kiosk browser pointed at this URL. Build the page once, every device reuses it.

## Flashing APOLLO / ARTEMIS (tate) — staged plan

Researched 2026-08-07. Goal: get off Android 4.0 stock so the tablet can run
**Fully Kiosk Browser** (auto-launch, always-on, wake-on-motion) as a real wall panel.

### Device confirmed
- **APOLLO serial `D025 A0A0 2383 0Q52`, ARTEMIS `D025 A0A0 3286 030M`** — both
  start `D025` = **tate** (Fire HD 7 2012, KFTT, 16GB). CONFIRMED safe.
- The brick-risk lookalike is **jem** (HD 8.9", serial `B0C…`, model KFJW…). We are
  NOT jem. **Only ever flash files labeled `tate` / `kfhd7`.** Wrong-model bootloader
  files (jem, or the 2013 "soho") = unrecoverable brick.

### ROM choice
- **LineageOS 14.1 (Android 7.1, unofficial by transi1)** — recommended. Runs modern
  Fully Kiosk *and* possibly the real Jellyfin Android app. Best usability on 1GB RAM.
- LineageOS 15.1 (Android 8.1) exists but is sluggish/experimental.
- CM11 (KitKat 4.4) — featherweight fallback; needs an *older* Fully Kiosk APK.
- All require Hashcode's **2nd-bootloader (freedom-boot/u-boot) + TWRP** installed first.

### Fully Kiosk needs NO Google apps
Sideload the APK with `adb install` — no Play Store, no GApps flash. Drops a whole
risky step. (For KitKat, grab an older Fully Kiosk APK; 7.1 takes current builds.)

### Host OS
- **Everything flashes from the Mac** (Apple Silicon): `brew install android-platform-tools`
  → native adb + fastboot. No Windows required (Kindle Fire First Aide is Windows-only
  but optional — the manual fastboot steps replace it).
- **Un-brick safety net = Linux** (omap4boot uses the OMAP4 boot ROM). Stage a Linux
  live-USB on the Windows PC or homelab *before starting*. A **factory/fastboot cable**
  (~$5, buy or DIY) means most bricks recover via plain fastboot and you never need omap4boot.

### FASTBOOT REQUIRES THE FACTORY CABLE (tested 2026-08-08)
Confirmed empirically: on stock FireOS 7.5.1, `adb reboot bootloader` makes APOLLO's
USB go completely dark — NO fastboot interface appears, on **either macOS or Linux**
(homelab). The stock Amazon bootloader simply doesn't expose fastboot over USB. So:
- **With the factory cable** (forces fastboot at power-on): NO rooting needed. Cable →
  fastboot → flash. This is the clean path. Cable ordered 2026-08-08 (N2A, ~Aug 13-17).
- **Without the cable:** the only route is rooting FireOS 7.5.1 first — but 7.5.1 is
  late firmware with the easy roots patched; uncertain + extra risk. Not worth it.
Decision: WAIT for the cable, skip rooting. Flashing host = homelab (Linux) or Mac;
both have adb/fastboot installed and both see APOLLO on adb fine over USB.

**USB 3.0 GOTCHA (researched 2026-08-08):** old Kindles are frequently NOT detected
in fastboot over a USB 3.0 / xhci port — a well-documented fastboot bug. Fix: native
USB 2.0. The M4 Mac and 2015 homelab are both USB-3-only; a USB-C hub / the iVANKY dock
DON'T help (they're 3.x — only true USB-2.0-gen silicon forces the downgrade).
**DEFINITIVELY CONFIRMED (2026-08-08):** `adb reboot bootloader` on stock tate does NOT
enter fastboot — tested on all three machines (M4 Mac, homelab Linux, VENGEANCE Windows)
and confirmed by watching APOLLO's screen: it just does a normal reboot to the lock
screen, never shows fastboot. Stock FireOS can't set the fastboot bootmode without root,
so the factory cable's hardware trigger is the ONLY way in. Not a USB-detection issue —
the device genuinely never enters fastboot. adb/USB/drivers all work fine on VENGEANCE
in normal mode (adb sees APOLLO), so flash-day setup is validated minus the cable.

**FLASH HOST = VENGEANCE** (Windows 11, `ssh vengeance`, adb/fastboot installed via scoop):
Windows has the best Kindle tooling (KFFA + drivers). CAVEAT: VENGEANCE is a modern AMD
board — ALL USB is xHCI (no legacy EHCI), so even its "USB 2.0" ports may still hit the
xHCI fastboot-detection bug once the cable puts APOLLO into fastboot. We couldn't test
detection (can't reach fastboot without the cable). So **KEEP the USB 2.0 hub order** as
insurance — a real 2.0-gen hub negotiates as a 2.0 device regardless of the xHCI controller.
The N2A factory cable (USB-A↔micro-USB) is the required trigger; cable ordered ~Aug 13-17.

### Ordered procedure (cable path — no root)
1. adb/fastboot ready on Mac AND homelab. APOLLO confirmed tate (serial `D025`, KFTT). ✓
2. Plug in the factory cable → APOLLO powers into fastboot.
3. **md5sum-verify** every image, then fastboot-flash Hashcode's tate 2nd-bootloader +
   freedom-boot + TWRP. **Blue logo on boot = success.** ← THE dangerous step.
4. Boot TWRP → **nandroid backup** of stock (your rollback).
5. Wipe system + factory reset (data/cache).
6. Flash the ROM zip (LineageOS 14.1 tate). No GApps needed.
7. First boot (slow), connect Wi-Fi, `adb install` Fully Kiosk APK, point it at
   `http://192.168.1.143:8092`, enable kiosk + motion-wake.

**Riskiest step is #3** (bootloader). Rules: tate-only files, md5sum everything, back
up first. A bootloop after the ROM flash (#6) is the *common, recoverable* failure —
re-enter TWRP and reflash.

### FULL KIT STAGED + VERIFIED (in `~/apollo-flash` on the Mac, manifest: CHECKSUMS.txt)
All four files downloaded and checksum-verified ✓ — flash day is pure execution:
- `kfhd7-u-boot-prod-7.2.3.bin` (md5 bb029673…) — AFH
- `kfhd7-freedom-boot-7.4.6.img` (md5 1628fc47…) — AFH
- `kfhd7-twrp-2.8.7.0-recovery.img` (md5 e5b97262…) — AFH
- `lineage-14.1-20180326-UNOFFICIAL-tate.zip` (sha256 4268b938…, Android 7.1) — transi1's
  MediaFire folder `u7sb7p10ik7v0` (folder also has crDroid 7.1.2 as an alt). Got direct
  link via MediaFire folder API `get_content.php?folder_key=…` (returns sha256) + the
  tokenized `downloadNNNN.mediafire.com` URL embedded in the file page.
AFH download trick: POST `androidfilehost.com/libs/otf/mirrors.otf.php` with
`submit=true&action=getdownloadmirrors&fid=<FID>` + header `X-MOD-SBB-CTYPE: xhr` → live mirror URL.
(The GitHub `kffa/32-bit` freedom-boot is a DIFFERENT unverified build — right size, wrong md5 —
deleted; do NOT use it.) **GApps: skip** — Fully Kiosk sideloads via `adb install`, no Play
Store needed. (If ever wanted: open_gapps arm 7.1 pico.) TRANSFER TO VENGEANCE before flash day.
APOLLO confirmed over ADB (from Mac, homelab, AND VENGEANCE): model KFTT, Android 4.0.3, 16GB.

### Files to grab (ALL `kfhd7-` = tate; goo.im & cyanogenmod.org are DEAD)
Bootloader/recovery (verified live 2026-08-07):
- `kfhd7-u-boot-prod-7.2.3.bin` (md5 `bb029673d8f186db4dff6d38f4aa28cf`) — AFH fid `24052804347764448`
- `kfhd7-freedom-boot-7.4.6.img` (md5 `1628fc4750d0d49cbce41ab616a9d732`, 8,341,488 bytes)
  — best mirror: GitHub raw `raw.githubusercontent.com/kffa/32-bit/master/kfhd7-freedom-boot.img`
  (byte-verified) — or AFH fid `24052804347764439`. Flash on stock/first-install ONLY, never re-flash after a ROM.
- `kfhd7-twrp-3.0.2-3-recovery.img` — AFH fid `24591000424959937` (newest) — or
  `kfhd7-twrp-2.8.7.0-recovery.img` (md5 `e5b9726244f143c21fe4e8365634624e`) fid `24052804347764441`
- Browse all tate files: AndroidFileHost `flid=94712` and `flid=30518`. (twrp.me has NO tate image — don't use it.)

ROM:
- LineageOS 14.1 (transi1) / CM builds — XDA "tate CyanogenMod ROM archive" thread,
  AndroidFileHost `flid=68326`, or Internet Archive `cyanogenmod-archive` (filter `-tate-`).
- GApps optional (skip for a pure Fully Kiosk panel): archive.org `open_gapps-arm-4.4-pico-20220215`.

### Un-brick kit (stage BEFORE flashing)
- **Factory/fastboot cable** (~$3–10 eBay, or DIY: short micro-USB pin 1↔pin 4). Forces
  fastboot at power-on — recovers most soft-bricks. A *bad* DIY cable can brick, so buy if unsure.
- **Soft-brick (fastboot reachable):** Kindle Fire First Aide + stock 7.4.3 + KFHD SRTool —
  all on `rootjunkysdl.com/?dir=Amazon+Kindle+Fire+HD+7in` (live). Also `github.com/kffa/noarch`.
- **Hard-brick (dead bootloader):** OMAP4460 boot-ROM `usbboot` on **Linux** — compile
  `github.com/rsalveti/omap4boot`, feed it the tate images above. No cable needed for this tier;
  the OMAP boot ROM is the hardware safety net that makes tate near-unbrickable.

**Practice on HADES first** — turn the one scary step (bootloader flash) into a free rehearsal.

## Status log

- **2026-08-07** — All five identified and documented; all charging, none rooted or
  flashed yet. **Samsung TV fully controllable + the GAIA control page is SHIPPED**
  (web remote on homelab, keys + volume + nav + DIAL app-launch all working). The
  control plane exists before any Kindle is ready — the tablets just point a kiosk
  browser at it. Decision still open on smart bulbs (Hue vs Kasa vs Home Assistant).

## Next actions (when ready, no rush)

1. Open `http://192.168.1.143:8092` on your phone — confirm the remote feels good,
   note any buttons to add/remove.
2. Copy `gaia_control.py` + the systemd unit into the dotfiles repo (version control).
3. Finish charging the fleet; confirm all five boot.
4. Deregister the Kindles from Sergio's / Yvette's Amazon accounts.
5. Root MINERVA (NookManager SD) — low-risk first hack.
6. Flash HADES (guinea pig) to learn the Fire workflow before APOLLO/ARTEMIS.
7. APOLLO: kiosk browser → the control page. Wall-mount. First "real" device.
