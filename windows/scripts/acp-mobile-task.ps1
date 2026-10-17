# Register (or refresh) the logon task that keeps acp-mobile running on this
# box, so SYZYGY phone access to NEMESIS survives a reboot.
#
# The task runs as the current user with the S4U logon type: no stored
# password, no console window, same profile (so ~/.acp-mobile, the Emacs
# server file under %APPDATA% and the Tailscale CLI all resolve). Logs go to
# %USERPROFILE%\.acp-mobile\{out,err}.log, same as a manual start.
#
# Usage (elevated not required):
#   powershell -NoProfile -ExecutionPolicy Bypass -File acp-mobile-task.ps1
#   powershell ... -File acp-mobile-task.ps1 -Start   # also start it now
param([switch]$Start)

$exe  = Join-Path $env:USERPROFILE 'bin\acp-mobile.exe'
$home_ = $env:USERPROFILE
$logDir = Join-Path $home_ '.acp-mobile'
if (-not (Test-Path $exe)) { throw "missing $exe; cross-compile it on the Mac (see macos/syzygy/README.md)" }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# cmd.exe does the redirection; Start-ScheduledTask has no stdout/stderr knobs.
$cmdLine = '/c ""' + $exe + '" 1>"' + (Join-Path $logDir 'out.log') + '" 2>"' + (Join-Path $logDir 'err.log') + '""'
$action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmdLine -WorkingDirectory $home_
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit ([TimeSpan]::Zero) `
               -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
               -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName 'acp-mobile' -Action $action -Trigger $trigger `
  -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "registered task 'acp-mobile' (at logon, S4U, hidden)"

if ($Start) {
  Get-Process acp-mobile -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-ScheduledTask -TaskName 'acp-mobile'
  Start-Sleep 4
  $p = Get-Process acp-mobile -ErrorAction SilentlyContinue
  if ($p) { Write-Output "acp-mobile running, pid $($p.Id)" } else { throw "acp-mobile did not start; see $logDir\err.log" }
}
