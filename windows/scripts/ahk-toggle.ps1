<#
.SYNOPSIS
  Turn AutoHotkey off and back on.  Usage: ahk-toggle.ps1 [on|off|status|toggle]

.DESCRIPTION
  EA Anticheat (Javelin: skate. on Steam, and other EA titles) refuses to start
  the game while ANY AutoHotkey process exists, hotkeys suspended or not. So
  "off" has to kill the interpreter, not just suspend the scripts.

    off     Kill every AutoHotkey process. The scripts they were running are
            recorded so "on" brings back exactly that set.
    on      Relaunch the recorded scripts. With no record, launch whatever
            AutoHotkey shortcuts are enabled in the Startup folder (the login
            state; *.lnk.disabled twins are skipped, same rule as bootstrap).
    status  List running AutoHotkey scripts.
    toggle  (default) off if anything is running, otherwise on.

  The PowerShell profile wraps this as `ahk`:  ahk off / ahk on / ahk.
#>
param(
    [ValidateSet('on', 'off', 'status', 'toggle')]
    [string]$Mode = 'toggle'
)
$ErrorActionPreference = 'Stop'

$StateFile = Join-Path $env:LOCALAPPDATA 'ahk-toggle.txt'

# Same resolution as bootstrap.ps1: the scoop shim dispatches on the script's
# "#Requires AutoHotkey v2.0"; the version-pinned apps\ path drifts.
function Get-AhkExe {
    $shim = "$env:USERPROFILE\scoop\shims\AutoHotkey.exe"
    if (Test-Path $shim) { return $shim }
    return "$env:USERPROFILE\scoop\apps\autohotkey\current\v2\AutoHotkey64.exe"
}

function Get-AhkProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'")
}

# The .ahk is the last script argument on the command line, quoted or not.
function Get-AhkScriptPath([string]$CommandLine) {
    if (-not $CommandLine) { return $null }
    $m = [regex]::Matches($CommandLine, '"([^"]+\.ahk)"|(\S+\.ahk)')
    if ($m.Count -eq 0) { return $null }
    $last = $m[$m.Count - 1]
    if ($last.Groups[1].Success) { $last.Groups[1].Value } else { $last.Groups[2].Value }
}

# Scripts behind the enabled AutoHotkey shortcuts in a Startup folder.
function Get-StartupAhkScripts([string]$Startup = [Environment]::GetFolderPath('Startup')) {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($lnk in Get-ChildItem -Path $Startup -Filter '*.lnk' -ErrorAction SilentlyContinue) {
        $sc = $ws.CreateShortcut($lnk.FullName)
        if ($sc.TargetPath -notmatch 'AutoHotkey') { continue }
        $script = Get-AhkScriptPath $sc.Arguments
        if ($script) { $script }
    }
}

# One entry per interpreter. The scoop shim (and AutoHotkey's own launcher) stays
# alive as the parent of the real AutoHotkey64.exe, so launcher parents are
# skipped here; Stop-Ahk still kills them.
function Get-RunningScripts {
    $procs = Get-AhkProcesses
    $parents = @($procs | ForEach-Object ParentProcessId)
    foreach ($p in $procs) {
        if ($parents -contains $p.ProcessId) { continue }
        [pscustomobject]@{ Pid = $p.ProcessId; Script = Get-AhkScriptPath $p.CommandLine }
    }
}

function Show-Status {
    $running = @(Get-RunningScripts)
    if ($running.Count -eq 0) { Write-Host 'AutoHotkey: off'; return }
    Write-Host "AutoHotkey: on ($($running.Count))"
    foreach ($r in $running) { Write-Host ("  {0,6}  {1}" -f $r.Pid, ($r.Script, '(no script)' -ne $null)[0]) }
}

function Stop-Ahk {
    $running = @(Get-RunningScripts)
    if ($running.Count -eq 0) { Write-Host 'AutoHotkey: already off'; return }
    $scripts = @($running | Where-Object Script | ForEach-Object Script | Select-Object -Unique)
    if ($scripts.Count) { $scripts | Set-Content -Path $StateFile -Encoding utf8 }
    # Kill launcher parents too, or the shim respawns nothing but still counts as
    # an AutoHotkey process to the anticheat.
    foreach ($p in Get-AhkProcesses) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($r in $running) { Write-Host "stopped  $($r.Script)" }
    Write-Host 'AutoHotkey: off  (ahk on brings these back)'
}

function Start-Ahk {
    if (Test-Path $StateFile) {
        $scripts = @(Get-Content $StateFile | Where-Object { $_ })
        Remove-Item $StateFile -Force
    } else {
        $scripts = @(Get-StartupAhkScripts)
    }
    if ($scripts.Count -eq 0) {
        Write-Host 'AutoHotkey: nothing to start (no record from "off", no enabled Startup shortcuts)'
        return
    }
    $exe = Get-AhkExe
    if (-not (Test-Path $exe)) { throw "AutoHotkey not found at $exe" }
    $already = @(Get-RunningScripts | ForEach-Object Script)
    foreach ($script in $scripts | Select-Object -Unique) {
        if ($already -contains $script) { Write-Host "running  $script"; continue }
        if (-not (Test-Path $script)) { Write-Warning "missing  $script"; continue }
        Start-Process -FilePath $exe -ArgumentList "`"$script`"" -WorkingDirectory (Split-Path $script -Parent)
        Write-Host "started  $script"
    }
}

# Dot-source to load the functions without acting (the tests do this).
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Mode) {
    'status' { Show-Status }
    'off'    { Stop-Ahk }
    'on'     { Start-Ahk }
    'toggle' { if ((Get-AhkProcesses).Count) { Stop-Ahk } else { Start-Ahk } }
}
