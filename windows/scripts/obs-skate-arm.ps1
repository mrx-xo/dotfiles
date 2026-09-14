<#
.SYNOPSIS
  Launch OBS "armed" for recording Skate clips: loads the Skate profile/scene,
  starts the replay buffer, and drops OBS to the tray. One key, ready to clip.

.DESCRIPTION
  Bound to Win+Shift+O via autohotkey\obs-skate.ahk. Sit down, hit the key, play;
  after you land a trick tap F10 (OBS's Save Replay hotkey) to write the last
  5 minutes to C:\Users\mnand\Videos\Skate.

  Idempotent: if OBS is already running we leave it alone (relaunching obs64 while
  an instance is up just pops an "OBS is already running" dialog), so mashing the
  hotkey never spawns duplicates.

  Flags:
    --startreplaybuffer   arm the replay buffer on launch (the whole point)
    --minimize-to-tray    stay out of the way of the game
    --disable-shutdown-check  skip the crash/Safe-Mode prompt if OBS was killed
                              uncleanly (e.g. force-quit), which would otherwise
                              block startup on a modal dialog
    --profile / --collection / --scene  pin the Skate setup regardless of whatever
                              profile happens to be the saved default
#>

$ErrorActionPreference = "Stop"

# obs64 must be launched with its own bin dir as the working directory, or it
# can't find its locale/plugin data.
$obsDir = "C:\Program Files\obs-studio\bin\64bit"
$obsExe = Join-Path $obsDir "obs64.exe"

if (-not (Test-Path $obsExe)) {
    Write-Host "OBS not found at $obsExe (install: winget install OBSProject.OBSStudio)" -ForegroundColor Yellow
    exit 1
}

if (Get-Process obs64 -ErrorAction SilentlyContinue) {
    # Already up (and presumably already armed) — nothing to do.
    exit 0
}

$obsArgs = @(
    "--disable-shutdown-check"
    "--startreplaybuffer"
    "--minimize-to-tray"
    "--profile",    "Skate"
    "--collection", "Skate"
    "--scene",      "Skate Gameplay"
)

Start-Process -FilePath $obsExe -WorkingDirectory $obsDir -ArgumentList $obsArgs
