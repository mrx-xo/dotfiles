# OBS config — Skate clip capture

Snapshot backup of the OBS Studio profile + scene collection used for recording
Skate gameplay clips on VENGEANCE. See `../docs/windows-keybinds.org` (OBS section)
and `../scripts/obs-skate-arm.ps1` for the launch/hotkey side.

## What's here

- `profiles/Skate/basic.ini` — output/video/audio settings: 1080p60 downscaled from
  1440p (Lanczos), NVENC H.264 CQP18, hybrid MP4 to `~\Videos\Skate`, 5-min replay
  buffer, F9/F10 hotkey stubs.
- `profiles/Skate/recordEncoder.json` — NVENC recording encoder (CQP 18, p6, hq).
- `scenes/Skate.json` — the "Skate" scene collection: `Skate Gameplay` scene with a
  `game_capture` source (any-fullscreen) + a `wasapi_process_output_capture`
  "Skate Audio" source (Skate.exe only, fader +10 dB) on track 1. The older
  `wasapi_output_capture` "Game Audio" (Sonar Gaming device) is still in the scene
  but muted, kept as a one-click revert.

These are a **point-in-time snapshot, not live-synced** — OBS rewrites its config
constantly, so we don't symlink it. After changing the setup in OBS, re-copy to
refresh the backup:

```powershell
$src = "$env:APPDATA\obs-studio"
Copy-Item "$src\basic\profiles\Skate\basic.ini","$src\basic\profiles\Skate\recordEncoder.json" .\profiles\Skate\ -Force
Copy-Item "$src\basic\scenes\Skate.json" .\scenes\ -Force
```

## Restore (fresh machine)

`bootstrap.ps1` copies these into `%APPDATA%\obs-studio\...` **only if missing**, so it
never clobbers a live config. To restore by hand:

```powershell
$dst = "$env:APPDATA\obs-studio"
Copy-Item .\profiles\Skate "$dst\basic\profiles\" -Recurse -Force
Copy-Item .\scenes\Skate.json "$dst\basic\scenes\" -Force
```

Then in `%APPDATA%\obs-studio\user.ini` set `[Basic] Profile=Skate` / `SceneCollection=Skate`.

## Not included (machine-local / secret)

- `plugin_config\obs-websocket\config.json` — holds the auto-generated websocket
  password; never committed. `bootstrap.ps1` just flips `server_enabled` on.
- `user.ini` / `global.ini` — machine-level OBS state (install GUID, window layout).

## Audio: why per-app capture

SteelSeries Sonar's channel sliders (Gaming/Media/Chat) are literally the Windows
master volume of the matching "SteelSeries Sonar - <channel>" virtual endpoint, and a
device capture of that endpoint sees the audio post-volume. With Gaming at 10% clips
came out ~35 dB too quiet, and every ears adjustment changed the clip.

The per-app "Skate Audio" source taps Skate.exe before that volume (verified
2026-09-16: Gaming 100% -> 50% moved the device capture by -10 dB and the per-app
capture not at all). Result:

- Sonar `Gaming` slider and the Windows volume keys: ears only.
- OBS mixer "Skate Audio" fader: clip level only. The per-app feed is ~13 dB quieter
  than the device loopback at unity, hence the +10 dB fader.
- Music can never leak in, whatever Sonar routes where.

The muted "Game Audio" source still references the Sonar Gaming device by GUID, which
is machine-specific; on another box re-pick it or just delete the source.

Diagnostics live in `../scripts/` and run fine over SSH (one script per PowerShell
process; the Add-Type COM classes clash otherwise):

```powershell
..\scripts\obs-audio-meter.ps1 15                        # OBS inputs + live peak/avg
..\scriptsudio-endpoints.ps1                           # Windows endpoints + volumes
..\scripts\set-endpoint-volume.ps1 -Match Speakers -Percent 25
..\scripts\obs-ws.ps1 -Requests '[{"requestType":"GetInputList"}]'
```
