# Installs Ollama as a background scheduled task.
# Copy ollama-serve.ps1 to the user profile before running this script.

$ErrorActionPreference = "Stop"

$taskName = "OllamaServe"
$serveScript = Join-Path $env:USERPROFILE "ollama-serve.ps1"
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not (Test-Path $serveScript)) {
    throw "Serve script not found at $serveScript"
}

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}
Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force

$arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
    $serveScript + '"'
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($startupTrigger, $logonTrigger) -Principal $principal `
    -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "OllamaServe installed and started for $userId"
