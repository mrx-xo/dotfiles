<#
  obs-ws.ps1 -Requests '<json array of {requestType, requestData}>'
  Generic obs-websocket v5 client: runs each request in order, prints the
  response JSON. Reads port/password from OBS's own plugin config.
  Example: obs-ws.ps1 -Requests '[{"requestType":"GetInputList"}]'
#>
param([Parameter(Mandatory)][string]$Requests)
$ErrorActionPreference = "Stop"
$cfg      = Get-Content "$env:APPDATA\obs-studio\plugin_config\obs-websocket\config.json" -Raw | ConvertFrom-Json
$port     = if ($cfg.server_port) { $cfg.server_port } else { 4455 }
$password = $cfg.server_password
$needAuth = [bool]$cfg.auth_required
$ct = [System.Threading.CancellationToken]::None

function Sha256B64([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    [Convert]::ToBase64String($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)))
}
function Send-Json($ws, $obj) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 20 -Compress))
    $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null
}
function Recv-Json($ws) {
    $buf = New-Object byte[] 65536
    $seg = [System.ArraySegment[byte]]::new($buf)
    $ms  = New-Object System.IO.MemoryStream
    do { $r = $ws.ReceiveAsync($seg, $ct).GetAwaiter().GetResult(); $ms.Write($buf, 0, $r.Count) } while (-not $r.EndOfMessage)
    [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([Uri]"ws://127.0.0.1:$port", $ct).GetAwaiter().GetResult() | Out-Null
$hello = Recv-Json $ws
$ident = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 0 } }
if ($needAuth -and $hello.d.authentication) {
    $secret = Sha256B64($password + $hello.d.authentication.salt)
    $ident.d.authentication = Sha256B64($secret + $hello.d.authentication.challenge)
}
Send-Json $ws $ident
if ((Recv-Json $ws).op -ne 2) { "identify failed"; exit 1 }

$i = 0
foreach ($r in ($Requests | ConvertFrom-Json)) {
    $i++
    $d = @{ requestType = $r.requestType; requestId = "r$i" }
    if ($r.requestData) { $d.requestData = $r.requestData }
    Send-Json $ws @{ op = 6; d = $d }
    do { $m = Recv-Json $ws } while ($m.op -ne 7)
    "--- $($r.requestType): ok=$($m.d.requestStatus.result) code=$($m.d.requestStatus.code) $($m.d.requestStatus.comment)"
    if ($m.d.responseData) { $m.d.responseData | ConvertTo-Json -Depth 20 }
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $ct).GetAwaiter().GetResult() | Out-Null
