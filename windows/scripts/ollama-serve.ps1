# Runs Ollama on this machine's Tailscale interface for fleet clients.
# The startup task may run before Tailscale has assigned its address, so wait
# for the adapter instead of binding a hard-coded address immediately.

$ErrorActionPreference = "Stop"

$log = Join-Path $env:USERPROFILE "ollama-serve.log"
$stdoutLog = Join-Path $env:USERPROFILE "ollama-serve.stdout.log"

trap {
    Add-Content -Path $log -Value `
        "$(Get-Date -Format o) startup failed: $($_.Exception.Message)"
    exit 1
}

$env:OLLAMA_CONTEXT_LENGTH = "64000"
$env:OLLAMA_KEEP_ALIVE = "-1"

$tailscale = Get-Command tailscale.exe -ErrorAction Stop
$tailscaleIP = $null
$deadline = (Get-Date).AddMinutes(2)

do {
    $candidate = & $tailscale.Source ip -4 2>$null | Select-Object -First 1
    if ($candidate) {
        $candidate = $candidate.Trim()
        $adapterAddress = Get-NetIPAddress -AddressFamily IPv4 `
            -IPAddress $candidate -ErrorAction SilentlyContinue
        if ($adapterAddress) {
            $tailscaleIP = $candidate
        }
    }

    if (-not $tailscaleIP) {
        Start-Sleep -Seconds 2
    }
} until ($tailscaleIP -or (Get-Date) -ge $deadline)

if (-not $tailscaleIP) {
    throw "Tailscale did not acquire an IPv4 address within 120 seconds"
}

$env:OLLAMA_HOST = $tailscaleIP
$ollama = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"

if (-not (Test-Path $ollama)) {
    throw "Ollama executable not found at $ollama"
}

Add-Content -Path $log -Value `
    "$(Get-Date -Format o) starting Ollama on $tailscaleIP with 64000 context"
$process = Start-Process -FilePath $ollama -ArgumentList "serve" `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $log `
    -NoNewWindow -Wait -PassThru
exit $process.ExitCode
