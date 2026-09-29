# One-time setup on VENGEANCE: register the mon-layout-normal and
# mon-layout-flipped scheduled tasks that monitor-mode.sh runs over SSH.
# Clones mon-assert's principal and settings (interactive desktop session,
# no stored password), so it can run from an SSH session; schtasks /create
# or /change would prompt for the account password.
$ErrorActionPreference = 'Stop'
$ref = Get-ScheduledTask -TaskName mon-assert
$repo = Join-Path $env:USERPROFILE 'dotfiles\windows\scripts'
foreach ($layout in 'normal', 'flipped') {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument (
        "`"$repo\run-hidden.vbs`" powershell -NoProfile -ExecutionPolicy Bypass " +
        "-File `"$repo\mon-layout.ps1`" -Layout $layout")
    Register-ScheduledTask -TaskName "mon-layout-$layout" -Action $action `
        -Principal $ref.Principal -Settings $ref.Settings -Force | Out-Null
    "registered mon-layout-$layout"
}
