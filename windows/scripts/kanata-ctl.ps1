<#
.SYNOPSIS
  Run kanata (home row mods) as an elevated scheduled task, and control it.
.DESCRIPTION
  kanata-ctl.ps1 install    register the "kanata" logon task (needs an elevated shell)
  kanata-ctl.ps1 uninstall  remove the task and stop kanata
  kanata-ctl.ps1 start      start the task now
  kanata-ctl.ps1 stop       end the task (kills kanata), sweep any leftover process
  kanata-ctl.ps1 restart    stop, then start (use after editing kanata.kbd)
  kanata-ctl.ps1 status     task state, last result, running process

  Why a task and not a Startup shortcut: kanata can only inject keys into
  windows at or below its own integrity level. Unelevated, the moment an
  elevated window (UAC prompt, Task Manager, admin terminal, anti-cheat)
  takes focus while a home-row mod is held, the key-up never lands and the
  modifier sticks, usually Super: every key turns into Win+key and the
  keyboard looks dead until a bare modifier is tapped. Running the task with
  RunLevel Highest removes that cause. Diagnosed 2026-07-20; the fix was
  lost until this script (2026-10-20).

  Why the GUI build, launched directly: Task Scheduler then owns the kanata
  process, so Stop-ScheduledTask kills it, and that works with the task
  owner's ordinary rights. Launching through wscript/run-hidden.vbs (the
  old shortcut's trick) orphans kanata from the task, and an unelevated
  caller can no longer kill the elevated process (tested 2026-10-20). The
  GUI build has no console window, so nothing to hide, and gives a tray icon.

  Escape hatch: Win+Shift+K (autohotkey\kanata-hatch.ahk) or its tray menu
  calls `stop` / `start` here from an unelevated AutoHotkey.

  Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less .ps1 as
  CP1252, so a stray Unicode dash or quote becomes a parser error.
#>
param(
    [ValidateSet('install', 'uninstall', 'start', 'stop', 'restart', 'status')]
    [string]$Command = 'status'
)
$ErrorActionPreference = 'Stop'

$KanataTaskName = 'kanata'
# scoop's `current` junction: if a scoop update leaves it dangling the task
# fails at logon; `scoop reset kanata` repairs it.
$KanataExe    = Join-Path $env:USERPROFILE 'scoop\apps\kanata\current\kanata_windows_gui_winIOv2_x64.exe'
$KanataConfig = Join-Path $env:USERPROFILE 'dotfiles\windows\kanata\kanata.kbd'

function Get-KanataActionArgument {
    "--cfg `"$KanataConfig`""
}

function Get-KanataProcessNames {
    # The GUI build is what the task runs; the tty/shim names cover a copy
    # started by hand from a terminal, so `stop` sweeps those too.
    @('kanata_windows_gui_winIOv2_x64', 'kanata', 'kanata_windows_tty_winIOv2_x64')
}

function Get-KanataProcess {
    Get-Process -Name (Get-KanataProcessNames) -ErrorAction SilentlyContinue
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-KanataTask {
    if (-not (Test-Elevated)) {
        throw 'install needs an elevated shell (RunLevel Highest is the whole point).'
    }
    if (-not (Test-Path $KanataExe)) {
        # An SSH session cannot always traverse scoop's junction even though
        # the desktop session can, so this is a warning, not a stop.
        Write-Warning "$KanataExe not visible from here (scoop install kanata vcredist2022, or scoop reset kanata). Registering anyway."
    }
    # Local accounts report USERDOMAIN=WORKGROUP, which Task Scheduler cannot
    # map; the identity name (COMPUTER\user) is what it wants.
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $KanataExe -Argument (Get-KanataActionArgument)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    Register-ScheduledTask -TaskName $KanataTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    # The old unelevated login shortcut would start a second, broken copy.
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'kanata.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk; "removed old Startup shortcut $lnk" }
    "registered task '$KanataTaskName' (elevated, at logon)"
}

function Uninstall-KanataTask {
    Stop-Kanata
    Unregister-ScheduledTask -TaskName $KanataTaskName -Confirm:$false -ErrorAction SilentlyContinue
    "removed task '$KanataTaskName'"
}

function Start-Kanata {
    if (Get-KanataProcess) { 'kanata already running'; return }
    Start-ScheduledTask -TaskName $KanataTaskName
    for ($i = 0; $i -lt 30 -and -not (Get-KanataProcess); $i++) { Start-Sleep -Milliseconds 100 }
    if (Get-KanataProcess) { 'kanata started' } else { throw 'task ran but no kanata process appeared; see status' }
}

function Stop-Kanata {
    # Ending the task kills the process it owns, with the owner's rights
    # alone. The sweep only matters for a copy started outside the task.
    Stop-ScheduledTask -TaskName $KanataTaskName -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20 -and (Get-KanataProcess); $i++) { Start-Sleep -Milliseconds 100 }
    $left = Get-KanataProcess
    if ($left) { $left | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300 }
    if (Get-KanataProcess) { throw 'kanata is still running (a copy outside the task needs an elevated shell to kill)' }
    'kanata stopped'
}

function Get-KanataStatus {
    $task = Get-ScheduledTask -TaskName $KanataTaskName -ErrorAction SilentlyContinue
    if (-not $task) { "task '$KanataTaskName': not registered (run install elevated)" }
    else {
        $info = $task | Get-ScheduledTaskInfo
        "task '$KanataTaskName': $($task.State), run level $($task.Principal.RunLevel)"
        "last run $($info.LastRunTime), result 0x$('{0:X}' -f $info.LastTaskResult)"
    }
    $proc = Get-KanataProcess
    if ($proc) { "process: $($proc.Name -join ', ') (pid $($proc.Id -join ', '))" }
    else { 'process: not running' }
}

if ($MyInvocation.InvocationName -ne '.') {
    switch ($Command) {
        'install'   { Install-KanataTask }
        'uninstall' { Uninstall-KanataTask }
        'start'     { Start-Kanata }
        'stop'      { Stop-Kanata }
        'restart'   { Stop-Kanata; Start-Kanata }
        'status'    { Get-KanataStatus }
    }
}
