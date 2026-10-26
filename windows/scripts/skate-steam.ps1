<#
.SYNOPSIS
  Launch skate. through Steam with AutoHotkey out of the way.  Usage: skate-steam.ps1

.DESCRIPTION
  EA Anticheat (Javelin) refuses to start skate. while any AutoHotkey process
  exists, and it keeps watching: AutoHotkey started while the game runs ends the
  game within seconds (seen 2026-10-20, exit code 0, no message). So this does
  what `ahk off` / Steam / play / `ahk on` does by hand, in order:

    1. ahk off            (ahk-toggle.ps1 records which scripts ran)
    2. steam://rungameid/3354750
    3. wait for Steam's Skate.exe, then wait for it to exit
    4. ahk on             (always, also when the game never showed up)

  The script therefore stays alive, hidden, for the whole session. If it gets
  killed, AutoHotkey stays down until `ahk on`.

  ReSkate (C:\Games\ReSkate) is not affected: its launcher starts its own
  Skate.exe without Javelin. Only the Steam copy is matched here: the Javelin-
  protected process hides its path from a normal user, so "Skate.exe with no
  readable path, or one under the Steam folder" is the Steam copy, and
  ReSkate's unprotected one is excluded by its C:\Games\ReSkate path.

  The Desktop shortcut "skate. (Steam)" runs this hidden through run-hidden.vbs;
  the profile wraps it as `skate`. Progress goes to %LOCALAPPDATA%\skate-steam.log
  and a message box reports a launch that never produced a game window.
#>
param(
    [int]$TimeoutSec = 300   # Steam -> EA launcher -> Skate.exe took 2.5 min cold on 2026-10-20
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ahk-toggle.ps1')

$AppId    = 3354750
$SteamExe = "${env:ProgramFiles(x86)}\Steam\steam.exe"
$GameDir  = "${env:ProgramFiles(x86)}\Steam\steamapps\common\Skate"
$LogFile  = Join-Path $env:LOCALAPPDATA 'skate-steam.log'

function Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

# Steam's Skate.exe only; ReSkate's copy has the same process name (see above).
function Get-SteamSkate {
    @(Get-Process -Name Skate -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Path -or $_.Path.StartsWith($GameDir, 'OrdinalIgnoreCase') })
}

if (-not (Test-Path $SteamExe)) { throw "Steam not found at $SteamExe" }

if ((Get-SteamSkate).Count) {
    Log 'skate. is already running; nothing to do'
    return
}

Log '--- launch'
Stop-Ahk
$failure = $null
try {
    Start-Process -FilePath $SteamExe -ArgumentList "steam://rungameid/$AppId"
    Log "asked Steam to run appid $AppId"

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Get-SteamSkate).Count -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
    }
    if (-not (Get-SteamSkate).Count) {
        Log "no Skate.exe after ${TimeoutSec}s"
        $failure = "Steam never started Skate.exe within $TimeoutSec s."
    } else {
        $started = Get-Date
        Log 'Skate.exe is up; AutoHotkey stays off until it exits'
        while ((Get-SteamSkate).Count) { Start-Sleep -Seconds 5 }
        $mins = [int]((Get-Date) - $started).TotalMinutes
        Log "Skate.exe exited after $mins min"
        if ($mins -lt 1) { $failure = 'Skate.exe quit within a minute of starting (anticheat?).' }
    }
} finally {
    Start-Ahk   # before any message box: nothing may hold AutoHotkey down
    Log 'AutoHotkey restored'
}

if ($failure) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("$failure`nAutoHotkey has been restored; see $LogFile.",
        'skate. (Steam)', 'OK', 'Warning') | Out-Null
}
