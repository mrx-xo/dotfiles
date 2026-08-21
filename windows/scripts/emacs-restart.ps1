<#
.SYNOPSIS
  Restart the Emacs daemon and open a fresh client frame.
.DESCRIPTION
  Windows port of the macOS scripts/emacs-restart.sh (which skhd triggers).
  Instead of launchd we just relaunch `runemacs --daemon` directly.
  Bind this to a hotkey (AutoHotkey, or a .lnk Shortcut key).
#>
$ErrorActionPreference = "SilentlyContinue"

# Prefer the scoop shims — the apps\emacs\current\bin path drifts across updates
# (the "current" junction and bin layout change between releases).
$shims    = "$env:USERPROFILE\scoop\shims"
$bin      = "$env:USERPROFILE\scoop\apps\emacs\current\bin"
$ec       = if (Test-Path "$shims\emacsclient.exe")  { "$shims\emacsclient.exe" }  else { "$bin\emacsclient.exe" }
$ecw      = if (Test-Path "$shims\emacsclientw.exe") { "$shims\emacsclientw.exe" } else { "$bin\emacsclientw.exe" }
$runemacs = if (Test-Path "$shims\runemacs.exe")     { "$shims\runemacs.exe" }     else { "$bin\runemacs.exe" }

# 1. Stop the running daemon gracefully (no-op if it isn't running).
$preexisting = @(Get-Process emacs -ErrorAction SilentlyContinue)
& $ec -e '(kill-emacs)' 2>$null | Out-Null

# 2. Force-kill anything that didn't go down.
#    The graceful kill above asks the daemon to kill *itself* over its server
#    socket — so it only works when the daemon is healthy. A daemon wedged
#    mid-init never registers a socket, making step 1 a silent no-op; without
#    this fallback each re-run stacked another daemon on top of the wedged one.
#    Only windowless processes are killed, so a standalone GUI Emacs survives.
if ($preexisting) {
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $preexisting.Id -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    $stuck = @(Get-Process -Id $preexisting.Id -ErrorAction SilentlyContinue |
               Where-Object { $_.MainWindowHandle -eq 0 })
    if ($stuck) {
        Write-Host "Force-killing wedged Emacs daemon(s): $($stuck.Id -join ', ')"
        $stuck | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# 3. Let the server socket clear, then start a fresh daemon (windowless).
Start-Sleep -Milliseconds 600
Start-Process -FilePath $runemacs -ArgumentList "--daemon" -WindowStyle Hidden

# 4. Wait (up to ~30s) for the daemon to accept connections.
$ready = $false
foreach ($i in 1..30) {
    Start-Sleep -Seconds 1
    & $ec -e '(+ 1 1)' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
}

# 5. Open a frame (empty -a "" also auto-starts the daemon if step 3 was slow).
if ($ready) {
    Start-Process -FilePath $ecw -ArgumentList '-c -a ""'
} else {
    $leftover = @(Get-Process emacs -ErrorAction SilentlyContinue)
    Write-Warning "Emacs daemon did not become ready within 30s."
    if ($leftover) {
        Write-Warning "Wedged process(es) still running: $($leftover.Id -join ', ')"
        Write-Warning "Re-run this script to clear them, or inspect init with:"
        Write-Warning "  emacs --batch -l `"`$env:APPDATA\.emacs.d\init.el`""
    }
}
