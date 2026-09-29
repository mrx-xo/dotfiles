# Run from the repo checkout on VENGEANCE by the mon-layout-normal and
# mon-layout-flipped scheduled tasks (desktop session, wrapped in
# run-hidden.vbs like every mon-* task). monitor-mode.sh chains it after
# mon-extend whenever both Dells show NEMESIS, and `mon flip` runs it alone.
#
# Arranges the two Dells left/right for the way they face:
#   normal  = facing west: ROMULUS left, REMUS right
#   flipped = facing east: the panels turn around, so REMUS is on the left
# Monitors are matched by serial, never by DISPLAYn (Windows renumbers).
# The primary stays at 0,0; the other panel moves to its left or right.
param([ValidateSet('normal', 'flipped')][string]$Layout = 'normal')

$ErrorActionPreference = 'Stop'
$mmt = 'C:\Tools\MultiMonitorTool\MultiMonitorTool.exe'
$csv = Join-Path $env:TEMP 'mon-layout.csv'
$log = 'C:\Tools\MultiMonitorTool\mon-layout.log'
$serial = @{ romulus = 'C3GZBY2'; remus = 'D8TYBY2' }

function Log($msg) { "$(Get-Date -Format s) [$Layout] $msg" | Add-Content $log }

function Read-Dells {
    Remove-Item $csv -ErrorAction SilentlyContinue
    & $mmt /scomma $csv
    for ($i = 0; $i -lt 20 -and -not (Test-Path $csv); $i++) { Start-Sleep -Milliseconds 100 }
    $rows = Import-Csv $csv
    $out = @{}
    foreach ($name in $serial.Keys) {
        $row = $rows | Where-Object { $_.'Monitor Serial Number' -eq $serial[$name] -and $_.Active -eq 'Yes' } |
            Select-Object -First 1
        if ($row) {
            $x, $y = $row.'Left-Top' -split ',\s*'
            $w = ($row.Resolution -split '\s*X\s*')[0]
            $out[$name] = [pscustomobject]@{
                Display = $row.Name; X = [int]$x; Y = [int]$y; Width = [int]$w
                Primary = $row.Primary -eq 'Yes'
            }
        }
    }
    $out
}

# mon-extend runs concurrently (schtasks /run returns immediately), so wait
# for both panels to be active before arranging them.
$dells = $null
for ($i = 0; $i -lt 20; $i++) {
    $dells = Read-Dells
    if ($dells.romulus -and $dells.remus) { break }
    Start-Sleep -Milliseconds 500
}
if (-not ($dells.romulus -and $dells.remus)) { Log 'skipped: both Dells not active'; exit 0 }

$left, $right = if ($Layout -eq 'normal') { 'romulus', 'remus' } else { 'remus', 'romulus' }
$wantRightOfLeft = $dells[$left].X + $dells[$left].Width -eq $dells[$right].X
if ($wantRightOfLeft -and $dells[$left].Y -eq $dells[$right].Y) { Log 'already arranged'; exit 0 }

# Keep whichever Dell is primary at 0,0 and move the other one.
if ($dells[$right].Primary) {
    $move = $left;  $x = $dells[$right].X - $dells[$left].Width; $pinY = $dells[$right].Y
} else {
    $move = $right; $x = $dells[$left].X + $dells[$left].Width;  $pinY = $dells[$left].Y
}
& $mmt /SetMonitors "Name=$($dells[$move].Display) PositionX=$x PositionY=$pinY"
Start-Sleep -Milliseconds 800
$after = Read-Dells
Log ("moved {0} to {1},{2}; now romulus={3},{4} remus={5},{6}" -f $move, $x, $pinY,
    $after.romulus.X, $after.romulus.Y, $after.remus.X, $after.remus.Y)
