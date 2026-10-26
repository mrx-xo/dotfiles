# Run with: pwsh -NoProfile -File windows/scripts/tests/kanata-ctl.test.ps1
# Dot-sources kanata-ctl.ps1 without dispatching a command and checks the
# pieces the scheduled task is built from. Runs anywhere pwsh runs, including
# macOS; nothing here touches Task Scheduler.
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = if ($env:USERPROFILE) { $env:USERPROFILE } else { '/tmp/fake-home' }
. (Join-Path $PSScriptRoot '..\kanata-ctl.ps1')

$failures = 0
function Assert($name, $cond) {
    if ($cond) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:failures++ }
}

Assert 'task name is the one the hatch and the runbook use' ($KanataTaskName -eq 'kanata')

# Task Scheduler must own the kanata process directly: no wscript/run-hidden
# in between, or an unelevated Stop-ScheduledTask (the hatch) cannot kill it.
Assert 'task runs the GUI build, which has no console to hide' ($KanataExe -match 'kanata_windows_gui_winIOv2_x64\.exe$')
Assert 'task resolves the exe through scoop''s current junction' ($KanataExe -match 'scoop[\\/]apps[\\/]kanata[\\/]current[\\/]')
$arg = Get-KanataActionArgument
Assert 'task argument is only the repo config' ($arg -match '^--cfg "[^"]*windows[\\/]kanata[\\/]kanata\.kbd"$')
Assert 'no run-hidden.vbs in the launch' ($arg -notmatch 'run-hidden')

$names = Get-KanataProcessNames
Assert 'process list leads with the GUI build the task runs' ($names[0] -eq 'kanata_windows_gui_winIOv2_x64')
Assert 'stop also sweeps a hand-started tty copy' ($names -contains 'kanata_windows_tty_winIOv2_x64')

if ($failures) { Write-Host "$failures failed"; exit 1 } else { Write-Host 'all passed'; exit 0 }
