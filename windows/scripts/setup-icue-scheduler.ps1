# Sets up the nightly iCUE lights-off scheduler on VENGEANCE.
# Idempotent. Requires: scoop (for uv), iCUE 5, dotfiles clone at ~\dotfiles.
# Lights off at 23:00 (ICUELightsOff runs icue-lights-off.py, which blanks
# LEDs and idles), back on at 08:00 (ICUELightsOn kills it; iCUE resumes).

$ErrorActionPreference = "Stop"

$venvDir = "$env:USERPROFILE\icue-scheduler"
$python  = "$venvDir\.venv\Scripts\python.exe"
$pythonw = "$venvDir\.venv\Scripts\pythonw.exe"
$script  = "$env:USERPROFILE\dotfiles\windows\scripts\icue-lights-off.py"

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    scoop install uv
}

if (-not (Test-Path $python)) {
    New-Item -ItemType Directory -Force -Path $venvDir | Out-Null
    uv venv --python 3.12 "$venvDir\.venv"
}
# cuesdk is Corsair's official binding; the similarly-named cue-sdk is not
uv pip install --python $python cuesdk

schtasks /create /f /tn ICUELightsOff /sc daily /st 23:00 /it `
    /tr "`"$pythonw`" `"$script`""
schtasks /create /f /tn ICUELightsOn /sc daily /st 08:00 `
    /tr "schtasks /end /tn ICUELightsOff"

Write-Host "Done. Test with: schtasks /run /tn ICUELightsOff"
