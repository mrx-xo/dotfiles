<#
  obs-audio-meter.ps1 [seconds]
  Diagnostic: list OBS audio inputs (device, fader dB, monitor type, mute, tracks)
  and sample live meters via obs-websocket for N seconds, reporting peak + average.
#>
param([int]$Seconds = 15)

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
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 10 -Compress))
    $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null
}
function Recv-Json($ws) {
    $buf = New-Object byte[] 65536
    $seg = [System.ArraySegment[byte]]::new($buf)
    $ms  = New-Object System.IO.MemoryStream
    do { $r = $ws.ReceiveAsync($seg, $ct).GetAwaiter().GetResult(); $ms.Write($buf, 0, $r.Count) } while (-not $r.EndOfMessage)
    [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}
function Req($ws, $type, $data, $id) {
    $d = @{ requestType = $type; requestId = $id }
    if ($data) { $d.requestData = $data }
    Send-Json $ws @{ op = 6; d = $d }
    do { $m = Recv-Json $ws } while ($m.op -ne 7 -or $m.d.requestId -ne $id)
    $m.d
}
function ToDb([double]$mul) { if ($mul -le 0) { [double]::NegativeInfinity } else { 20 * [math]::Log10($mul) } }
function FmtDb([double]$db) { if ([double]::IsNegativeInfinity($db)) { "-inf" } else { "{0,6:N1} dB" -f $db } }

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ws.ConnectAsync([Uri]"ws://127.0.0.1:$port", $ct).GetAwaiter().GetResult() | Out-Null
$hello = Recv-Json $ws
# eventSubscriptions: InputVolumeMeters = 1 << 16 (high-volume event, opt-in)
$ident = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 65536 } }
if ($needAuth -and $hello.d.authentication) {
    $secret = Sha256B64($password + $hello.d.authentication.salt)
    $ident.d.authentication = Sha256B64($secret + $hello.d.authentication.challenge)
}
Send-Json $ws $ident
$idm = Recv-Json $ws
if ($idm.op -ne 2) { "identify failed (op=$($idm.op))"; exit 1 }

"=== OBS audio inputs ==="
$inputs = (Req $ws "GetInputList" $null "list").responseData.inputs |
    Where-Object { $_.inputKind -match "wasapi|dshow|coreaudio|pulse" }
foreach ($i in $inputs) {
    $n   = $i.inputName
    $vol = (Req $ws "GetInputVolume" @{ inputName = $n } "vol").responseData
    $mon = (Req $ws "GetInputAudioMonitorType" @{ inputName = $n } "mon").responseData.monitorType
    $mut = (Req $ws "GetInputMute" @{ inputName = $n } "mute").responseData.inputMuted
    $trk = (Req $ws "GetInputAudioTracks" @{ inputName = $n } "trk").responseData.inputAudioTracks
    $set = (Req $ws "GetInputSettings" @{ inputName = $n } "set").responseData.inputSettings
    $tracks = ($trk.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name }) -join ","
    "  * $n  [$($i.inputKind)]"
    "      device  : $($set.device_id)"
    "      fader   : $("{0:N1}" -f $vol.inputVolumeDb) dB   monitor: $mon   muted: $mut   tracks: $tracks"
}

"=== Sampling meters for ${Seconds}s (play something loud) ==="
$stats = @{}
$deadline = (Get-Date).AddSeconds($Seconds)
$ws.Options | Out-Null
while ((Get-Date) -lt $deadline) {
    $m = Recv-Json $ws
    if ($m.op -ne 5 -or $m.d.eventType -ne "InputVolumeMeters") { continue }
    foreach ($inp in $m.d.eventData.inputs) {
        $n = $inp.inputName
        if (-not $inp.inputLevelsMul -or $inp.inputLevelsMul.Count -eq 0) { continue }
        if (-not $stats[$n]) { $stats[$n] = @{ n = 0; sig = 0; peak = 0.0; sum = 0.0 } }
        $s = $stats[$n]
        # inputLevelsMul: per channel [magnitude, peak, inputPeak]
        $pk = ($inp.inputLevelsMul | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum
        $mg = ($inp.inputLevelsMul | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum
        $s.n++
        if ($pk -gt 0) { $s.sig++; $s.sum += $mg }
        if ($pk -gt $s.peak) { $s.peak = $pk }
    }
}
$ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", $ct).GetAwaiter().GetResult() | Out-Null

foreach ($n in $stats.Keys) {
    $s = $stats[$n]
    $avg = if ($s.sig) { $s.sum / $s.sig } else { 0 }
    "  $n : $($s.n) readings, $($s.sig) with signal   PEAK $(FmtDb (ToDb $s.peak))   AVG $(FmtDb (ToDb $avg))"
}
if ($stats.Count -eq 0) { "  no meter events received" }
