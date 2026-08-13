#!/usr/bin/env python3
"""SYZYGY launcher — always-on front door for the acp-mobile UI.

Runs on GAIA (homelab), which is up when MrX isn't. The phone's
home-screen clip points HERE instead of at MrX directly:

  - MrX reachable  -> instant JS redirect into the real UI (invisible hop)
  - MrX dark       -> honest "unreachable" page with a Wake button that
                      fires wakeonlan from this box, polls until :8090
                      answers, then redirects

Authkey rides through as ?authkey=... (or #authkey=...) and is forwarded
on redirect; without it the phone's 1-year acp-mobile cookie still works.

Deploy: macos/syzygy/gaia-launcher/deploy.sh (scp + systemd unit).
Stdlib only — no pip, nothing to rot.
"""

import json
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8091
MRX_MAC = "98:fc:84:e9:ab:e7"  # MrX en8 wired LAN (see wake-m4.sh)
MRX_URL = "http://mrx.tail9179e0.ts.net:8090"
WAKE_COOLDOWN_S = 5.0

_last_wake = 0.0

PAGE = """<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="SYZYGY">
<meta name="theme-color" content="#1d2021">
<title>SYZYGY</title>
<style>
  :root {
    --bg: #1d2021; --bg1: #3c3836; --bg2: #504945;
    --fg: #ebdbb2; --fg-mute: #928374;
    --orange: #fe8019; --yellow: #fabd2f; --green: #b8bb26; --red: #fb4934;
    --mono: ui-monospace, "SF Mono", Menlo, monospace;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: var(--mono); background: var(--bg); color: var(--fg);
    height: 100dvh; display: flex; flex-direction: column;
    align-items: center; justify-content: center; gap: 18px;
    text-align: center; padding: 24px;
  }
  #mark { font-size: 22px; font-weight: 700; letter-spacing: 6px; }
  #mark .dim { color: var(--fg-mute); }
  #status { font-size: 14px; color: var(--fg-mute); min-height: 20px; }
  #status.err { color: var(--red); }
  #status.ok { color: var(--green); }
  #wake {
    display: none; font-family: var(--mono); font-size: 16px; font-weight: 700;
    color: var(--bg); background: var(--orange); border: none;
    border-radius: 12px; padding: 14px 34px; cursor: pointer;
  }
  #wake:active { opacity: 0.7; }
  #wake.visible { display: block; }
  #spin { font-size: 18px; color: var(--yellow); min-height: 24px; }
</style>
</head><body>
<div id="mark">SYZ<span class="dim">Y</span>GY</div>
<div id="spin"></div>
<div id="status">reaching MrX&hellip;</div>
<button id="wake">Wake MrX</button>
<script>
const MRX = %MRX_URL%;
const statusEl = document.getElementById('status');
const wakeBtn = document.getElementById('wake');
const spinEl = document.getElementById('spin');
const FRAMES = ['\\u280b','\\u2819','\\u2839','\\u2838','\\u283c','\\u2834','\\u2826','\\u2827','\\u2807','\\u280f'];
let spinT = null, spinI = 0;
function spinStart() {
  if (!spinT) spinT = setInterval(() => {
    spinEl.textContent = FRAMES[spinI = (spinI + 1) %% FRAMES.length];
  }, 80);
}
function spinStop() { clearInterval(spinT); spinT = null; spinEl.textContent = ''; }

// Authkey arrives as ?authkey= or #authkey= and is forwarded on the
// redirect; without one the phone's long-lived acp-mobile cookie covers it.
function authkey() {
  const q = new URLSearchParams(location.search).get('authkey');
  if (q) return q;
  const m = location.hash.match(/authkey=([0-9a-f]+)/);
  return m ? m[1] : null;
}
function enter() {
  const k = authkey();
  location.replace(k ? MRX + '/?authkey=' + k : MRX + '/');
}
// no-cors probe: an opaque response (even a 429) means the box answered;
// only a network-level failure rejects.
function probe(ms) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  return fetch(MRX + '/', {mode: 'no-cors', cache: 'no-store', signal: ctl.signal})
    .then(() => { clearTimeout(t); return true; })
    .catch(() => { clearTimeout(t); return false; });
}

async function boot() {
  spinStart();
  if (await probe(3000)) { statusEl.textContent = 'connected'; enter(); return; }
  spinStop();
  statusEl.textContent = "can't reach MrX \\u2014 asleep or offline";
  statusEl.className = 'err';
  wakeBtn.classList.add('visible');
}

wakeBtn.addEventListener('click', async () => {
  wakeBtn.classList.remove('visible');
  statusEl.className = '';
  statusEl.textContent = 'sending magic packet\\u2026';
  spinStart();
  try {
    const r = await fetch('wake', {method: 'POST'});
    if (!r.ok) throw new Error('wake endpoint said ' + r.status);
  } catch (e) {
    spinStop();
    statusEl.textContent = 'wake failed: ' + e.message;
    statusEl.className = 'err';
    wakeBtn.classList.add('visible');
    return;
  }
  // ~2 min of polling: cold boot + tailnet reconnect can take a while.
  const t0 = Date.now();
  while (Date.now() - t0 < 120000) {
    const dt = Math.round((Date.now() - t0) / 1000);
    statusEl.textContent = 'waking MrX\\u2026 ' + dt + 's';
    if (await probe(2500)) {
      statusEl.textContent = 'MrX is up';
      statusEl.className = 'ok';
      enter();
      return;
    }
    await new Promise(res => setTimeout(res, 2500));
  }
  spinStop();
  statusEl.textContent = 'still dark after 2 min \\u2014 box may be fully off, or WoL never reached it';
  statusEl.className = 'err';
  wakeBtn.classList.add('visible');
});

boot();
</script>
</body></html>
""".replace("%MRX_URL%", json.dumps(MRX_URL)).replace("%%", "%")


class Handler(BaseHTTPRequestHandler):
    server_version = "syzygy-launcher"

    def do_GET(self):
        if self.path.split("?")[0].split("#")[0] in ("/", "/index.html"):
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        global _last_wake
        if self.path != "/wake":
            self.send_error(404)
            return
        now = time.time()
        if now - _last_wake < WAKE_COOLDOWN_S:
            self._json(429, {"error": "cooldown"})
            return
        _last_wake = now
        # Three packets, spaced out — WoL is fire-and-forget UDP.
        ok = True
        for i in range(3):
            r = subprocess.run(["wakeonlan", MRX_MAC],
                               capture_output=True, text=True)
            ok = ok and r.returncode == 0
            if i < 2:
                time.sleep(0.3)
        self.log_message("wake requested by %s -> wakeonlan %s (ok=%s)",
                         self.client_address[0], MRX_MAC, ok)
        self._json(200 if ok else 500, {"ok": ok})

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"syzygy-launcher on :{PORT} -> {MRX_URL} (mac {MRX_MAC})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
