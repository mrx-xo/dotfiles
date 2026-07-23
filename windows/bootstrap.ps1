<#
.SYNOPSIS
  Symlink dotfiles from this repo into their live Windows locations, and
  create the Emacs daemon-autostart and client launcher shortcuts.
.NOTES
  Requires either Developer Mode ON (Settings > Privacy & security > For developers)
  or running this script as Administrator, so that symlinks can be created.
  Re-running is safe and idempotent.

  Run from the windows/ subdirectory of the monorepo (cd windows first); every
  path is derived from $PSScriptRoot, so shortcuts point at windows\... paths.

  Dependencies (install via scoop before running; missing ones are skipped
  with a warning rather than installed):
    scoop install emacs autohotkey starship glazewm kanata vcredist2022 syncthing
    scoop install FiraCode-NF FiraCode-NF-Mono Iosevka-NF-Mono CascadiaCode-NF   # fonts
    scoop install jellyfin-media-player   # desktop client for a Jellyfin server
  AutoHotkey is required for the Emacs global hotkeys (autohotkey\emacs.ahk).
  Starship + CascadiaCode-NF power the riced PowerShell prompt (powershell\).
  GlazeWM is the tiling window manager (config in glazewm\config.yaml).
  kanata provides home row mods (config in kanata\kanata.kbd); needs vcredist2022.
  Syncthing keeps ~/shared in sync across machines. This script only wires the
  autostart shortcut + creates ~/shared; each machine's Syncthing config (device
  identity, keys, the `shared` folder def, device pairing) is machine-local and
  NOT in the repo — set it up per machine via the GUI at http://127.0.0.1:8384
  (add the `shared` folder pointed at ~/shared with folder id `shared`, then pair).
#>

$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot

# Map: repo file  ->  live location
$links = @{
    "$repo\emacs\.emacs.d\init.el"            = "$env:APPDATA\.emacs.d\init.el"
    "$repo\emacs\.emacs.d\early-init.el"      = "$env:APPDATA\.emacs.d\early-init.el"
    "$repo\windows-terminal\settings.json"    = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    "$repo\powershell\Microsoft.PowerShell_profile.ps1" = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) "WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
    "$repo\powershell\starship.toml"          = "$env:USERPROFILE\.config\starship.toml"
}

foreach ($target in $links.Keys) {
    $link = $links[$target]
    $dir  = Split-Path $link -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # Back up an existing real file (not an existing symlink) before replacing it.
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if (-not $item.LinkType) {
            Copy-Item $link "$link.bak" -Force
            Write-Host "Backed up existing $link -> $link.bak" -ForegroundColor Yellow
        }
    }

    New-Item -ItemType SymbolicLink -Path $link -Target $target -Force | Out-Null
    Write-Host "Linked $link -> $target" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Emacs daemon: autostart on login + a client launcher shortcut.
# Shortcuts can't be symlinked from the repo, so we (re)create them here.
# ---------------------------------------------------------------------------
$emacsBin     = "$env:USERPROFILE\scoop\apps\emacs\current\bin"
$runemacs     = "$emacsBin\runemacs.exe"
$emacsclientw = "$emacsBin\emacsclientw.exe"
$emacsExe     = "$emacsBin\emacs.exe"

if (Test-Path $runemacs) {
    $ws = New-Object -ComObject WScript.Shell

    # Autostart the daemon (windowless) on login.
    $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "Emacs Daemon.lnk"
    $sc = $ws.CreateShortcut($startupLnk)
    $sc.TargetPath       = $runemacs
    $sc.Arguments        = "--daemon"
    $sc.WorkingDirectory = $env:USERPROFILE
    $sc.Description       = "Start Emacs server (daemon) on login"
    $sc.WindowStyle      = 7   # minimized / no window
    $sc.Save()
    Write-Host "Created startup shortcut -> $startupLnk" -ForegroundColor Green

    # Desktop launcher: open a frame, starting the daemon if it isn't running.
    # Arguments are stored literally here, so the empty -a "" survives (PowerShell
    # mangles it on the command line).
    $clientLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Emacs Client.lnk"
    $sc = $ws.CreateShortcut($clientLnk)
    $sc.TargetPath       = $emacsclientw
    $sc.Arguments        = '-c -a ""'
    $sc.WorkingDirectory = $env:USERPROFILE
    $sc.IconLocation     = "$emacsExe,0"
    $sc.Description       = "Open an Emacs frame (connects to daemon, starts it if needed)"
    $sc.Save()
    Write-Host "Created client shortcut  -> $clientLnk" -ForegroundColor Green
} else {
    Write-Host "Emacs not found at $emacsBin - skipping daemon/client shortcuts." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Emacs global hotkeys (AutoHotkey) — autostart the .ahk on login.
# (Win+Shift+E open frame, Win+Shift+R restart; see autohotkey\emacs.ahk.)
# ---------------------------------------------------------------------------
$ahkExe    = "$env:USERPROFILE\scoop\apps\autohotkey\current\v2\AutoHotkey64.exe"
$ahkScript = "$repo\autohotkey\emacs.ahk"

if ((Test-Path $ahkExe) -and (Test-Path $ahkScript)) {
    $ws = New-Object -ComObject WScript.Shell
    $hotkeysLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "Emacs Hotkeys.lnk"
    $sc = $ws.CreateShortcut($hotkeysLnk)
    $sc.TargetPath       = $ahkExe
    $sc.Arguments        = "`"$ahkScript`""
    $sc.WorkingDirectory = Split-Path $ahkScript -Parent
    $sc.Description       = "Emacs global hotkeys (AutoHotkey)"
    $sc.Save()
    Write-Host "Created hotkeys shortcut  -> $hotkeysLnk" -ForegroundColor Green
} else {
    Write-Host "AutoHotkey or emacs.ahk not found - skipping hotkeys shortcut." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# GlazeWM fullscreen auto-pause (AutoHotkey) — autostart on login.
# Pauses GlazeWM whenever a fullscreen app (game / video) is focused, so it
# stops fighting borderless-fullscreen games. No per-game ignore list needed;
# see autohotkey\glaze-game-pause.ahk for the why.
# ---------------------------------------------------------------------------
$gamePauseScript = "$repo\autohotkey\glaze-game-pause.ahk"

if ((Test-Path $ahkExe) -and (Test-Path $gamePauseScript)) {
    $ws = New-Object -ComObject WScript.Shell
    $gamePauseLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "GlazeWM Game Pause.lnk"
    $sc = $ws.CreateShortcut($gamePauseLnk)
    $sc.TargetPath       = $ahkExe
    $sc.Arguments        = "`"$gamePauseScript`""
    $sc.WorkingDirectory = Split-Path $gamePauseScript -Parent
    $sc.Description       = "Auto-pause GlazeWM while a fullscreen app is focused"
    $sc.Save()
    Write-Host "Created game-pause shortcut -> $gamePauseLnk" -ForegroundColor Green
} else {
    Write-Host "AutoHotkey or glaze-game-pause.ahk not found - skipping game-pause shortcut." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# GlazeWM tiling WM — Windows port of yabai/skhd.
#
# We used to run komorebi + whkd here, but komorebi's AF_UNIX IPC is broken on
# this machine (komorebic connect() -> os error 10022 / WSAEINVAL on Win11 25H2),
# which killed every hotkey. GlazeWM uses a localhost WebSocket/TCP IPC instead,
# sidestepping that whole class of Windows AF_UNIX breakage. It also has a
# built-in keybind engine, so whkd is no longer needed.
#
# Developer Mode is off, so rather than symlink config.yaml into ~/.glzr we launch
# `glazewm start --config <repo file>`. No admin, and it never goes stale on save.
# ---------------------------------------------------------------------------

# Clean up the old komorebi wiring if it's still around (idempotent).
foreach ($v in "KOMOREBI_CONFIG_HOME", "WHKD_CONFIG_HOME") {
    if ([Environment]::GetEnvironmentVariable($v, "User")) {
        [Environment]::SetEnvironmentVariable($v, $null, "User")
        Write-Host "Removed stale env var $v" -ForegroundColor Yellow
    }
}
$oldKomorebiLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "komorebi.lnk"
if (Test-Path $oldKomorebiLnk) {
    Remove-Item $oldKomorebiLnk -Force
    Write-Host "Removed stale startup shortcut -> $oldKomorebiLnk" -ForegroundColor Yellow
}

$glazewm   = "$env:USERPROFILE\scoop\shims\glazewm.exe"
$glazeConf = "$repo\glazewm\config.yaml"

if (Test-Path $glazewm) {
    $ws = New-Object -ComObject WScript.Shell
    $glazeLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "GlazeWM.lnk"
    $sc = $ws.CreateShortcut($glazeLnk)
    $sc.TargetPath       = $glazewm
    $sc.Arguments        = "start --config `"$glazeConf`""
    $sc.WorkingDirectory = $env:USERPROFILE
    $sc.Description       = "Start GlazeWM tiling WM on login (config from dotfiles repo)"
    $sc.WindowStyle      = 7   # minimized / no window
    $sc.Save()
    Write-Host "Created startup shortcut -> $glazeLnk" -ForegroundColor Green
} else {
    Write-Host "GlazeWM not found (scoop install glazewm) - skipping autostart." -ForegroundColor Yellow
}

# Free up Win+L so GlazeWM can bind Super+l (focus right). Win+L (lock) is OS-
# reserved and unblockable until lock-workstation is disabled. This is a per-user
# policy, but the Policies key is ACL-locked, so the write needs admin. Trade-off:
# the machine can no longer be locked (sleep / sign out instead). Reverse: set to 0.
try {
    $polPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    if (-not (Test-Path $polPath)) { New-Item -Path $polPath -Force | Out-Null }
    New-ItemProperty -Path $polPath -Name "DisableLockWorkstation" -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "Set DisableLockWorkstation = 1 (frees Win+L for GlazeWM)" -ForegroundColor Green
} catch {
    Write-Host "Could not set DisableLockWorkstation (needs admin). Run bootstrap elevated, or set HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System\DisableLockWorkstation = 1 (DWORD) manually." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# kanata — home row mods (Ctrl/Alt/Super/Shift on a s d f / j k l ;).
# Mirrors the CASG layout from the programmable keyboard. Launched with
# --cfg pointing straight at the repo (no symlink, no admin), same as GlazeWM.
# Note: kanata only remaps non-elevated windows unless it runs elevated; the
# login shortcut runs unelevated, which is fine for normal use.
# ---------------------------------------------------------------------------
$kanata     = "$env:USERPROFILE\scoop\shims\kanata.exe"
$kanataConf = "$repo\kanata\kanata.kbd"

if (Test-Path $kanata) {
    $ws = New-Object -ComObject WScript.Shell
    $kanataLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "kanata.lnk"
    $sc = $ws.CreateShortcut($kanataLnk)
    $sc.TargetPath       = $kanata
    $sc.Arguments        = "--cfg `"$kanataConf`""
    $sc.WorkingDirectory = $env:USERPROFILE
    $sc.Description       = "Start kanata home row mods on login (config from dotfiles repo)"
    $sc.WindowStyle      = 7   # minimized / no window
    $sc.Save()
    Write-Host "Created startup shortcut -> $kanataLnk" -ForegroundColor Green
} else {
    Write-Host "kanata not found (scoop install kanata vcredist2022) - skipping autostart." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Syncthing — background file sync for ~/shared across machines. The scoop shim
# injects `--home <scoop persist>\config --no-upgrade`, so config + device
# identity live in scoop's persist dir (machine-local, contains keys — never
# committed). We only wire the login autostart and ensure ~/shared exists; the
# `shared` folder + device pairing are set up per machine via the GUI
# (http://127.0.0.1:8384). `serve --no-browser` runs it windowless with no
# browser popup on login (also set startBrowser=false in its config).
# ---------------------------------------------------------------------------
$shared = "$env:USERPROFILE\shared"
if (-not (Test-Path $shared)) {
    New-Item -ItemType Directory -Force -Path $shared | Out-Null
    Write-Host "Created $shared" -ForegroundColor Green
}

$syncthing = "$env:USERPROFILE\scoop\shims\syncthing.exe"

if (Test-Path $syncthing) {
    $ws = New-Object -ComObject WScript.Shell
    $syncthingLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "Syncthing.lnk"
    $sc = $ws.CreateShortcut($syncthingLnk)
    $sc.TargetPath       = $syncthing
    $sc.Arguments        = "serve --no-browser"
    $sc.WorkingDirectory = $env:USERPROFILE
    $sc.Description       = "Start Syncthing (background sync for ~/shared) on login"
    $sc.WindowStyle      = 7   # minimized / no window
    $sc.Save()
    Write-Host "Created startup shortcut -> $syncthingLnk" -ForegroundColor Green
} else {
    Write-Host "Syncthing not found (scoop install syncthing) - skipping autostart." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Machine identity (fleet-wide convention, see machines/ in the repo root).
# ~/.config/machine-id is the source of truth read by `whereami` and agents
# landing here over SSH (which get Git Bash, where $HOME/.config resolves).
# MACHINE_ID is also set as a user env var so PowerShell sessions see it.
# ---------------------------------------------------------------------------
$configDir = "$env:USERPROFILE\.config"
if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }
$machineIdFile = "$configDir\machine-id"
if (-not (Test-Path $machineIdFile)) {
    # -NoNewline + ASCII: Git Bash `cat` chokes on BOM/CRLF from Set-Content defaults
    [System.IO.File]::WriteAllText($machineIdFile, "vengeance`n", [System.Text.Encoding]::ASCII)
    Write-Host "Wrote $machineIdFile (vengeance)" -ForegroundColor Green
}
[Environment]::SetEnvironmentVariable("MACHINE_ID", "vengeance", "User")

Write-Host "`nDone. Your live configs now point at the repo." -ForegroundColor Cyan
