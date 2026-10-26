# Windows dotfiles

Personal Windows configs, managed as symlinks from this repo.

## What's here

| Path | Symlinks to |
|------|-------------|
| `emacs/.emacs.d/init.el` | `%APPDATA%\.emacs.d\init.el` |
| `emacs/.emacs.d/early-init.el` | `%APPDATA%\.emacs.d\early-init.el` |
| `windows-terminal/settings.json` | Windows Terminal `LocalState\settings.json` |
| `powershell/Microsoft.PowerShell_profile.ps1` | `Documents\WindowsPowerShell\…_profile.ps1` |
| `powershell/starship.toml` | `~/.config/starship.toml` |

The repo is the source of truth — edit files here (or in their live location, since
they're symlinked, it's the same file) and git tracks the changes.

## Shared Emacs picker behavior

Both Emacs configs load
[`mr-x-minibuffer.el`](../macos/emacs/.emacs.d/lisp/mr-x-minibuffer.el).
Its location under `macos/` is historical; edit this one module for both
platforms instead of adding separate Consult/Vertico interaction settings.
Package installation remains in each platform's init file.

`C-s` starts with empty input; the symbol at point remains available in
search history. In the bottom picker, Enter accepts the highlighted command,
search result, or file. A selected directory is entered without closing the
picker. Directory-aware deletion and picker sizing also match the Mac.
This does not change Corfu completion popups inside editing buffers.

After editing, load the module with `M-x load-file` in the running Emacs;
no daemon restart is needed. If search still prefills or Enter returns partial
input, check for later platform overrides of `consult-line`'s `:initial` or
`vertico-map`'s `RET`, then reload the module. To roll back, restore the prior
module and matching init changes together, and load the restored settings.

Behavior tests live in
[`minibuffer-tests.el`](../macos/emacs/.emacs.d/tests/minibuffer-tests.el).
Run them with the installed Consult/Vertico packages on each platform.
Window placement and Super-key delivery are separate work.

## SYZYGY phone access (acp-mobile on NEMESIS)

The same Go pair the Macs run, cross-compiled for Windows. Emacs starts
Claude through `acp-multiplex.exe`, which exposes each session as a Unix
socket under `%TEMP%\acp-multiplex\<pid>.sock`; `acp-mobile.exe` serves
those to the phone on port 8090 behind `tailscale serve`, so the URL is
`https://vengeance.<tailnet>.ts.net` and only the tailnet can reach it.
Scope today is view and reply on existing Claude chats; see the SYZYGY
Lisp paragraph below for what the Windows Emacs loads and what is still
missing.

Pieces:

- Binaries: `%USERPROFILE%\bin\acp-{multiplex,mobile}.exe`, built on the Mac
  with `GOOS=windows GOARCH=amd64 go build` from `~/src/acp-multiplex` and
  `~/src/acp-mobile` on the `syzygy` branches, then copied with
  `scp ... vengeance:bin/`. `%USERPROFILE%\bin` is not on Emacs's PATH, so
  `init.el` points `agent-shell-anthropic-claude-acp-command` at the absolute
  exe when it exists and otherwise keeps the direct `claude-agent-acp`.
- State: `%USERPROFILE%\.acp-mobile\` holds `authkey`, `link` (the URL to
  open on the phone), `vapid.json`, and `out.log` / `err.log`. Go resolves
  home to `%USERPROFILE%`; Emacs resolves `~` to `%APPDATA%`. Keep that in
  mind before sharing a path between the two.
- Startup: [`scripts/acp-mobile-task.ps1`](scripts/acp-mobile-task.ps1)
  registers a hidden at-logon scheduled task (`acp-mobile`, S4U, no stored
  password). `-Start` also (re)starts it now. HTTPS was enabled once with
  `tailscale serve --bg 8090`; it persists.

Health check, from NEMESIS:

```
powershell -NoProfile -Command "Get-ScheduledTask acp-mobile | Select -Expand State"
dir %TEMP%\acp-multiplex
type %USERPROFILE%\.acp-mobile\err.log
```

No `.sock` files means no Claude session has been started through the
multiplex since the last reboot; the command variable only takes effect for
shells started after `init.el` loaded with the exe present. Rotate the key by
deleting `authkey` and restarting the task. Updating the binaries is a new
cross-compile plus `scp`, then rerun the task script with `-Start`.

The SYZYGY Lisp tests run headless from PowerShell, against a temporary
state directory rather than `%USERPROFILE%\.acp-mobile`:

```
powershell -NoProfile -File %USERPROFILE%\dotfiles\shared\emacs\tests\run-syzygy-tests.ps1
```

To run it against another checkout, set `SYZYGY_DOTFILES_ROOT` to that
checkout's root first; the default is `%USERPROFILE%\dotfiles`.

The Windows init loads SYZYGY from `shared/emacs/lisp/syzygy/` with
`(require 'syzygy)` after the shared `load-path` block, which pulls in
`syzygy-rig`. NEMESIS therefore writes the `status.json` and labels
sidecars under `%USERPROFILE%\.acp-mobile\`, so the phone shows idle/busy
and titles for its sessions. New-chat presets, on the desk's `SPC c P` and
the phone's spawn sheet alike, are the Windows list in
[`agent-shell-extras.el`](emacs/.emacs.d/lisp/agent-shell-extras.el): it loads
before SYZYGY, so its `mr-x/agent-shell-presets` wins and the shared picker
and spawn helpers in `syzygy-rig.el` run on it. The remaining Windows
overrides (spec section 6.7) are step 3 and later.

NEMESIS is a SYZYGY fleet node: POLLUX's phone app lists and relays its
sessions. The real prerequisite is `%USERPROFILE%\.acp-mobile\config.json`
listing the hub, `{"hubs": ["<hub MagicDNS name>"]}`; without it NEMESIS
refuses every hub call and shows `asleep`. `tailscale` must also be on the
machine PATH (the installer does it); an `extraPath` entry for
`C:\Program Files\Tailscale` in the same file is optional. Restart with the
task script's `-Start` after editing it. See the Fleet section of
[`macos/syzygy/README.md`](../macos/syzygy/README.md#fleet-one-phone-app-for-every-machine).

## Setup on a new machine

1. Enable **Developer Mode** (Settings → Privacy & security → For developers),
   so symlinks can be created without admin. *(Or run the script as Administrator.)*
2. Clone this repo.
3. Run the bootstrap:
   ```powershell
   .\bootstrap.ps1
   ```
   It backs up any existing real config to `*.bak`, then replaces it with a symlink
   into this repo. Re-running is safe.

## PowerShell prompt (riced)

Gruvbox [Starship](https://starship.rs) prompt themed to match the rest of the setup
(gold `#fabd2f` accent, gold `◇` prompt char mirroring the Emacs agent-shell symbol).
Needs a Nerd Font for glyphs — Windows Terminal is set to `CaskaydiaCove NF`
(the family name the `CascadiaCode-NF` scoop package registers; *not* "...Nerd Font").

```powershell
scoop install starship CascadiaCode-NF
```

The profile also enables PSReadLine history autosuggestions (↑/↓ search, Tab
menu-complete) and a few aliases (`ll`, `g`, `gs`, `gl`, `which`, `..`, `dotfiles`).

## Window manager (GlazeWM)

[GlazeWM](https://github.com/glzr-io/glazewm) is the tiling WM — a Windows port of
the macOS yabai/skhd setup. Config lives in `glazewm/config.yaml` (gruvbox gold
borders, 10px gaps, `alt`-focus / `alt+shift`-move / `ctrl+alt`-resize, workspaces
`alt+1..5`). It has a built-in keybind engine, so there's no separate hotkey daemon.

```powershell
scoop install glazewm
```

> **Why not komorebi?** We started on komorebi + whkd, but komorebi's IPC is an
> AF_UNIX socket and on this machine (Win11 25H2) `komorebic`'s `connect()` fails
> with `os error 10022` (WSAEINVAL), killing every hotkey. It's a known class of
> Windows AF_UNIX breakage. GlazeWM's IPC is a localhost WebSocket/TCP server, which
> dodges it entirely.

Unlike the symlinked configs above, `config.yaml` is **not** symlinked into `~/.glzr`
(symlinks need admin here). `bootstrap.ps1` instead creates a login shortcut that runs
`glazewm start --config <repo file>`, so GlazeWM reads straight from the repo — no
admin, and it never goes stale when an editor rewrites the file on save.

## Home row mods (kanata)

[kanata](https://github.com/jtroo/kanata) turns the home row into modifiers — each key
is its letter when tapped, a modifier when held. Mirrors the programmable keyboard's
**CASG** layout (pinky → index):

| Keys | Hold = |
|------|--------|
| `a` `;` | Ctrl |
| `s` `l` | Alt |
| `d` `k` | Super (Windows key) |
| `f` `j` | Shift |

Config is `kanata/kanata.kbd` (adapted from kanata's `home-row-mod-advanced` sample —
bilateral combinations + no-mods-while-typing to avoid misfires). Super (`d`/`k`) is
GlazeWM's modifier, so you drive the WM from the home row.

```powershell
scoop install kanata vcredist2022
```

### How it runs

kanata runs as the **`kanata` scheduled task**: elevated (RunLevel Highest), at
logon, launching the GUI build `kanata_windows_gui_winIOv2_x64.exe --cfg <repo file>`
directly. `bootstrap.ps1` registers it when run elevated; by hand:

```powershell
scripts\kanata-ctl.ps1 install     # elevated shell
```

Why elevated: kanata can only inject into windows at or below its own integrity
level. Unelevated, when an elevated window (UAC prompt, Task Manager, admin
terminal, anti-cheat) took focus while a home-row mod was held, the key-up never
landed and the modifier stuck — usually Super, so every key became Win+key
(Win+C Copilot, Win+I Settings) and the keyboard looked dead until a bare modifier
was tapped. That was the "keys randomly stop working" bug (diagnosed 2026-07-20,
fix re-landed 2026-10-20). The old unelevated `kanata.lnk` Startup shortcut is
gone; a leftover `kanata.lnk.disabled` is harmless.

Why the task launches the exe directly: Task Scheduler then owns the process, so
ending the task kills kanata with the task owner's ordinary rights. Through
`run-hidden.vbs` the process is orphaned and an unelevated caller cannot kill it.

### Escape hatch

`autohotkey\kanata-hatch.ahk` (autostarted by `bootstrap.ps1`, unelevated):

- **Win+Shift+K** toggles kanata off / on and releases every modifier. The hotkey
  is wildcarded, so it still fires with a stuck modifier attached.
- **Tray icon → `kanata: toggle`** does the same by mouse, for when the keyboard is
  the problem.

From a terminal, no elevation needed:

```powershell
scripts\kanata-ctl.ps1 status | start | stop | restart
```

`restart` is the reload after editing `kanata.kbd`. Validate edits first with
`kanata --cfg kanata\kanata.kbd --check`. Tune `tap-time` / `hold-time` if you get
misfires.

### Troubleshooting

- **Keys dead or everything is Win+key**: Win+Shift+K (or tap each of Ctrl, Alt,
  Shift and Win once). If kanata was off, Win+Shift+K again turns it back on.
- **Task fails at logon** (`status` shows a non-zero result, no process): scoop's
  `apps\kanata\current` junction is probably dangling after an update — `scoop reset
  kanata`, then `kanata-ctl.ps1 start`.
- **`stop` says a copy outside the task is running**: something started kanata by
  hand; kill it from an elevated shell, then use the task only.
- **Park it**: `schtasks /change /tn kanata /disable` keeps the task but stops it
  starting at logon; `kanata-ctl.ps1 uninstall` removes it.

## Ollama background service

`scripts/ollama-serve.ps1` waits for this machine's Tailscale IPv4 address, then
starts Ollama tailnet-only with a 64,000-token default context and persistent model
residency. `scripts/setup-ollama-serve.ps1` installs it as the `OllamaServe` task with
startup and logon triggers, background login, and failure retries.

Deploy the serve script to the user profile, then run the setup script from
PowerShell. Re-running setup is safe.

```powershell
Copy-Item .\scripts\ollama-serve.ps1 "$HOME\ollama-serve.ps1" -Force
.\scripts\setup-ollama-serve.ps1
```

Verify with `schtasks /query /tn OllamaServe /v /fo list` and `ollama ps`.

## Notes

- On machines without Developer Mode / admin, `bootstrap.ps1`'s symlinks fail; the
  PowerShell profile + `starship.toml` can instead be **hardlinked** (no elevation,
  same live-edit behavior): `New-Item -ItemType HardLink`.
- Symlinks mean editing the config in Emacs/Terminal updates the repo directly — just
  `git add -p && git commit` to save changes.
- To migrate later (e.g. fold into a cross-platform dotfiles repo), this whole folder
  can move into a `windows/` subdirectory; only the paths in `bootstrap.ps1` would need
  adjusting.

## Resident lighting HTTP API

`scripts/icue-lights.py` starts `scripts/icue_http.py` alongside its existing
lighting loop. The API uses only the Python standard library; neither the API
nor `shared/lights/schedule.py` imports the hardware SDK. The shared schedule
preserves the local-clock 08:00–23:00 window and next-boundary override expiry,
including DST. Mac CLI commands and the existing interactive Windows logon task
retain their behavior.

### Configuration and firewall

Set configuration in the environment inherited by the driver's logon task:

- `ICUE_HTTP_HOST`: bind IP literal, default `0.0.0.0`; IPv6 literals are also
  supported. Hostnames and empty values are rejected.
- `ICUE_HTTP_PORT`: decimal port 1–65535, default `7790`.
- `ICUE_HTTP_ALLOWED_NETWORKS`: comma-separated network CIDRs. **Replaces all
  defaults**, which are `127.0.0.0/8,::1/128,100.64.0.0/10`. Include those ranges
  explicitly when adding deployment-specific LAN ranges. Keep private network
  configuration outside this public repository.

This is trusted-network access, with no user authentication or TLS. Every HTTP
method checks the socket peer before reading a body; forwarded headers confer
no access. RFC6598 admits only `100.64.0.0/10`, not all `100.*` addresses.
`/health` confirms the API is answering, not that the lighting engine is healthy.
Invalid configuration or bind failure is logged and the lighting schedule
continues without HTTP.

From the repository's `windows` directory, scheduler setup remains unelevated:

```powershell
.\scripts\setup-icue-scheduler.ps1
```

It invokes the firewall helper only if the session is already elevated.
Otherwise it prints the exact helper command to run separately from PowerShell
as Administrator. It never opens an elevation prompt. The standalone step is:

```powershell
.\scripts\setup-icue-firewall.ps1
```

The helper requires administrator rights and creates or updates the named
`ICUELights-HTTP` inbound TCP rule, with `Profile Any` and restricted remote
ranges. It reads the same port/network environment variables; explicit `-Port`
and `-AllowedNetworks` parameters override them. Use identical settings in the
administrator session and the driver's logon environment. Rerunning updates the
existing rule instead of accumulating rules. Other independently configured
firewall rules are not removed. Changing environment variables does not
reconfigure a running driver or firewall rule automatically.

### Endpoint contract

1. `GET /health`: 200 with `{"ok":true,"engine":"icue-lights"}`.
2. `GET /status`: observed status fields plus `age` (seconds since the opened
   status file's mtime), `effect_list`, `effect_current`, and `descriptions`.
   Missing/corrupt status or corrupt existing control returns 503. A valid stale
   status remains 200 with its actual age and old observed state; clients should
   treat `age >= 10` as unavailable. Future mtimes produce age zero.
3. `POST /control`: accepts a JSON object with only `effect`, `brightness`, and
   `force`, each optional. Success is 200 with `accepted: true` plus the status
   response fields. **This acknowledges control acceptance, not applied LEDs.**

`effect_list` is the effects module's named effects, `random`, and one
`preset: <name>` selection per preset. `effect_current` reflects the selected
control setting, even at night. Observed `effect`, `on`, `brightness`, and other
engine fields always come from status, and may lag the accepted selection.
Removed stored effect/preset names follow the driver's rotation fallback and
remain repairable through a valid effect patch; malformed stored types fail.

Example patch:

```json
{"effect":"random","brightness":0.5,"force":"on"}
```

Named effects pin a selection; `preset: <name>` resumes that rotation pool;
`random` rolls fresh parameters. Brightness must be finite numeric input (never
boolean), clamped to 0.01–1.0. `force` accepts `"on"`, `"off"`, or `null`.
On/off sets expiry to the next local 08:00 or 23:00; null removes both override
keys. An empty object is an accepted no-op patch. Unmanaged settings, including
fan overrides and parameters when not rolling, are preserved.

All validation completes before mutation. **POST preflights observed status
before writing:** absent/corrupt status returns 503 without changing control.
Success includes that preflight snapshot, even if the driver rewrites or removes
status immediately afterward. Missing control uses the driver's defaults
(rotation mode, rotation preset, brightness 1.0); corrupt existing control is
refused with 503 rather than losing settings. A client polls status after success.

Requests require `Content-Type: application/json` and one valid `Content-Length`.
Bodies are limited to 8192 bytes. Unknown keys/selections, malformed or non-object
JSON, NaN/Infinity, invalid lengths, and transfer encoding are rejected. Errors
use 400 (invalid input/framing), 403 (peer denied), 404 (unknown endpoint),
408 (body timeout), 411 (missing length), 413 (oversized body), 415 (media type),
or 503 (state/write unavailable). Invalid requests leave control byte-identical.

### Concurrency and lifecycle

The threaded server allows at most 16 active connections, with a two-second
socket inactivity timeout and a five-second absolute request deadline, including
headers. Connections close after one response. Overload closes new connections;
header timeout/deadline expiry may close without an HTTP response. Slow clients
cannot retain unbounded workers. Deadlines bound network I/O, not filesystem I/O.

HTTP writers hold a lock across read/modify/write and use a same-directory
temporary file, flush/fsync, then atomic replace.
The replace retries Windows sharing/access failures up to five attempts over
80 ms, allowing the resident reader to close its short-lived handle. Persistent
failure returns 503 and preserves the old file. Windows readers may also receive
a transient sharing/access error while replacement completes; readable contents
remain whole JSON. The stress test checks atomic contents and recovery after
contention, not that every competing operation succeeds.

**The legacy SSH writer does
not share this lock.** Concurrent SSH and HTTP updates can still lose a setting;
a partial SSH write can temporarily cause 503. Avoid simultaneous use of both
transports. The driver's existing non-atomic status writes can likewise produce
brief 503 responses during a read; no fresh device state is invented.

`start_server(control_file, status_file, effects_module, host=None, port=None,
allowed_networks=None)` returns a running server. None arguments use the
configuration above; explicit arguments override environment values. Explicit
`port=0` is available for ephemeral test listeners only. On exit the caller must
invoke `server.shutdown()` then `server.server_close()` from outside the serving
thread. Closing interrupts active client sockets and joins handlers. On Windows,
a blocked receive may remain until the two-second socket timeout expires. The driver
does this on graceful stop and exception unwinding before handing back its layer.

Development checks (no hardware access):

```sh
python3 -m unittest discover -s shared/lights/tests -v
python3 -m unittest discover -s windows/scripts/tests -v
```

Run from the repository root with a current Python (3.12+). PowerShell syntax,
firewall changes, and physical SDK behavior require separate Windows validation.
