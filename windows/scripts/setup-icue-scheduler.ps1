# Sets up the resident Corsair lighting driver on VENGEANCE.
# Idempotent. Requires: scoop (for uv), iCUE 5, dotfiles clone at ~\dotfiles.
# One logon task (ICUELights) runs icue-lights.py forever: rotating effects
# 08:00-23:00 (new effect every 5 min), black overnight. To stop it and give
# lighting back to iCUE: type nul > ~\icue-scheduler\stop.flag

$ErrorActionPreference = "Stop"

$venvDir = "$env:USERPROFILE\icue-scheduler"
$python  = "$venvDir\.venv\Scripts\python.exe"
$script  = "$env:USERPROFILE\dotfiles\windows\scripts\icue-lights.py"
$vbs     = "$env:USERPROFILE\dotfiles\windows\scripts\run-hidden.vbs"

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    scoop install uv
}

if (-not (Test-Path $python)) {
    New-Item -ItemType Directory -Force -Path $venvDir | Out-Null
    uv venv --python 3.12 "$venvDir\.venv"
}
# cuesdk is Corsair's official binding; the similarly-named cue-sdk is not
uv pip install --python $python cuesdk

# Not pythonw: uv-venv pythonw.exe is a trampoline that spawns *console*
# python.exe, and a GUI parent means the child allocates a fresh VISIBLE
# console — the mystery empty terminal on every boot. Run console python
# through run-hidden.vbs instead: its hidden console is inherited down the chain.
schtasks /create /f /tn ICUELights /sc onlogon /it `
    /tr "wscript.exe `"$vbs`" `"$python`" `"$script`""

Write-Host "Done. Start now with: schtasks /run /tn ICUELights"
