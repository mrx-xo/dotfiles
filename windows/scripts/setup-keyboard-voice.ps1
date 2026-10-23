# Register an on-demand action in the existing desktop user's session.
# No stored password, service account, persistent helper, or logon trigger.
param(
    [string]$AutoHotkeyPath = "$env:USERPROFILE\scoop\apps\autohotkey\current\v2\AutoHotkey64.exe"
)
$ErrorActionPreference = 'Stop'
$reference = Get-ScheduledTask -TaskName mon-assert
# Invoke the v2 interpreter directly, not Scoop's GUI launcher shim.
# SSH may reject Scoop's current junction; pass its concrete version path then.
$ahk = (Get-Item -LiteralPath $AutoHotkeyPath -ErrorAction Stop).FullName
$script = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\autohotkey\keyboard-voice-toggle.ahk'))
if (-not (Test-Path $script)) { throw "Missing action script: $script" }
$principal = New-ScheduledTaskPrincipal -UserId $reference.Principal.UserId `
    -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 15)
$action = New-ScheduledTaskAction -Execute $ahk -Argument ('"' + $script + '"')
Register-ScheduledTask -TaskName keyboard-voice-toggle -Action $action `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Output 'Registered keyboard-voice-toggle (interactive user, limited privileges)'
