# hz-probe.ps1 -- what refresh rate is each desktop display REALLY at?
#
# Runs assert-hz.ps1 inside the interactive desktop session through a
# throwaway scheduled task and prints its six GDI passes. Needed because
# an SSH session (session 0) has no desktop displays: EnumDisplaySettings
# returns nothing there and the assert reports -1 for every pass.
# Driven from the Mac by `monitor-mode.sh hz`; deployed copy lives at
# C:\Tools\MultiMonitorTool\hz-probe.ps1 next to assert-hz.ps1.
# Side effect: like every assert-hz run, a display found below 154 Hz is
# re-asserted to 155 -- so pass 1 is the reading that matters.
$ErrorActionPreference = 'Stop'
$ref = Get-ScheduledTask -TaskName mon-assert
$log = 'C:\Tools\MultiMonitorTool\hz-probe.log'
Remove-Item $log -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument (
    "/c powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden " +
    "-File C:\Tools\MultiMonitorTool\assert-hz.ps1 > `"$log`" 2>&1")
Register-ScheduledTask -TaskName mon-hz-probe -Action $action `
    -Principal $ref.Principal -Settings $ref.Settings -Force | Out-Null
Start-ScheduledTask -TaskName mon-hz-probe
Start-Sleep -Seconds 18
Get-Content $log
Unregister-ScheduledTask -TaskName mon-hz-probe -Confirm:$false
