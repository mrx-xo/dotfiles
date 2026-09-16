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
  `game_capture` source (any-fullscreen) + a `wasapi_output_capture` "Game Audio"
  source on track 1.

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

## Caveat: audio device is machine-specific

"Game Audio" captures the **SteelSeries Sonar - Gaming** virtual device by its device
GUID. That GUID is specific to this machine's Sonar install — on a different box (or a
Sonar reinstall) re-pick the device in the source's Properties. Music exclusion also
depends on routing the music app to Sonar's **Media** channel (SteelSeries GG side).
