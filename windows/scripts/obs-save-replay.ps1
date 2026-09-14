<#
.SYNOPSIS
  Save the OBS replay buffer (the last N minutes) to disk via obs-websocket.

.DESCRIPTION
  Bound to a hotkey by autohotkey\obs-skate.ahk. We drive the save over
  obs-websocket (built into OBS 28+, port 4455) instead of an OBS global hotkey,
  because OBS's raw-key hotkeys proved unreliable here — a keyboard Fn-lock can
  send media codes instead of F10, and OBS never registered a hand-edited binding.
  A websocket request is deterministic and never depends on which window has focus.

  Reads the port + password from OBS's own plugin config so no secret lives in the
  repo and it works on any machine. Requires the replay buffer to be running (the
  launcher arms it with --startreplaybuffer); if it isn't, OBS returns an error we
  surface. Saved clips land in the profile's recording folder (~\Videos\Skate),
  prefixed "SkateReplay".

  Exit codes: 0 saved, 1 could not save (not armed / OBS down / bad response).
#>

$ErrorActionPreference = "Stop"

$cfgPath = "$env:APPDATA\obs-studio\plugin_config\obs-websocket\config.json"
if (-not (Test-Path $cfgPath)) { Write-Host "obs-websocket config not found ($cfgPath)"; exit 1 }
$cfg      = Get-Content $cfgPath -Raw | ConvertFrom-Json
$port     = if ($cfg.server_port) { $cfg.server_port } else { 4455 }
$password = $cfg.server_password
$needAuth = [bool]$cfg.auth_required

$ct = [System.Threading.CancellationToken]::None

function Sha256B64([string]$s) {
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
    [Convert]::ToBase64String($hash)
}
function Send-Json($ws, $obj) {
    $json  = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg   = [System.ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null
}
function Recv-Json($ws) {
    $buf = New-Object byte[] 16384
    $seg = [System.ArraySegment[byte]]::new($buf)
    $ms  = New-Object System.IO.MemoryStream
    do {
        $r = $ws.ReceiveAsync($seg, $ct).GetAwaiter().GetResult()
        $ms.Write($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

$ws = New-Object System.Net.WebSockets.ClientWebSocket
try {
    $ws.ConnectAsync([Uri]"ws://127.0.0.1:$port", $ct).GetAwaiter().GetResult() | Out-Null

    # op 0 Hello -> op 1 Identify (with auth if the server asks for it)
    $hello  = Recv-Json $ws
    $ident  = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 0 } }
    if ($needAuth -and $hello.d.authentication) {
        $secret = Sha256B64($password + $hello.d.authentication.salt)
        $ident.d.authentication = Sha256B64($secret + $hello.d.authentication.challenge)
    }
    Send-Json $ws $ident
    $identified = Recv-Json $ws          # op 2 Identified
    if ($identified.op -ne 2) { Write-Host "auth/identify failed (op=$($identified.op))"; exit 1 }

    # op 6 Request -> op 7 RequestResponse
    Send-Json $ws @{ op = 6; d = @{ requestType = "SaveReplayBuffer"; requestId = "save" } }
    $resp = Recv-Json $ws
    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $ct).GetAwaiter().GetResult() | Out-Null

    if ($resp.d.requestStatus.result) {
        Write-Host "Replay saved."
        exit 0
    } else {
        # code 604 = output not active (replay buffer not running)
        Write-Host "Save failed: $($resp.d.requestStatus.comment) (code $($resp.d.requestStatus.code))"
        exit 1
    }
} catch {
    Write-Host "Could not reach OBS websocket on port $port ($($_.Exception.Message)). Is OBS running and armed?"
    exit 1
}
