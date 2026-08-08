#!/usr/bin/env python3
"""GAIA control — web remote for the living-room Samsung Q60BD.

Keys/volume/nav go over the Tizen WebSocket API (samsungtvws).
App launches use DIAL (HTTP POST) — WebSocket run_app is locked down on 2022+
firmware. Power-on uses Wake-on-LAN (API is dead when the TV is fully off).

The HTML is deliberately old-browser-safe (no CSS grid, no CSS variables, no
fetch()) so it renders on APOLLO's 2012 Fire HD browser, not just modern phones.
"""
import os
import socket
import requests
from flask import Flask, jsonify, send_from_directory
from samsungtvws import SamsungTVWS

MOCKDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mocks")

TV_HOST = "192.168.1.153"
TV_MAC = "A0:D7:F3:7F:C6:04"
TOKEN_FILE = "/home/home-lab/tvctl/token.txt"
PORT = 8092

# The apps this household actually uses. id=None => not wired yet ("soon").
# Vix/Angel need IDs pulled off the TV; Jellyfin needs sideloading first.
APPS = [
    {"name": "YouTube",  "id": "111299001912", "glyph": "▶"},
    {"name": "Vix",      "id": None,           "glyph": "V"},
    {"name": "Angel",    "id": None,           "glyph": "A"},
    {"name": "Jellyfin", "id": None,           "glyph": "J"},
]

app = Flask(__name__)
_tv = None


def _conn():
    global _tv
    if _tv is None:
        _tv = SamsungTVWS(host=TV_HOST, port=8002, token_file=TOKEN_FILE,
                          name="homelab-remote", timeout=12)
    return _tv


def send_key(key):
    global _tv
    try:
        _conn().send_key(key)
    except Exception:
        _tv = None
        _conn().send_key(key)


def wol(mac):
    packet = b"\xff" * 6 + bytes.fromhex(mac.replace(":", "").replace("-", "")) * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.sendto(packet, ("255.255.255.255", 9))
    s.close()


@app.post("/key/<key>")
def key(key):
    send_key(key if key.startswith("KEY_") else "KEY_" + key)
    return jsonify(ok=True)


@app.post("/app/<app_id>")
def launch(app_id):
    r = requests.post(f"http://{TV_HOST}:8001/api/v2/applications/{app_id}", timeout=5)
    return jsonify(ok=r.status_code == 200, code=r.status_code)


@app.post("/wake")
def wake():
    wol(TV_MAC)
    return jsonify(ok=True)


@app.get("/m")
@app.get("/m/<name>")
def mock(name="obsidian"):
    p = os.path.join(MOCKDIR, os.path.basename(name) + ".html")
    if not os.path.isfile(p):
        return "not found", 404
    with open(p, encoding="utf-8") as f:
        return f.read()


@app.get("/img/<name>")
def img(name):
    return send_from_directory(MOCKDIR, os.path.basename(name))


@app.get("/")
def index():
    tiles = ""
    for a in APPS:
        if a["id"]:
            tiles += (
                '<button class="tile" onclick="tap(this);post(\'/app/%s\')">'
                '<span class="g">%s</span><span class="n">%s</span></button>'
                % (a["id"], a["glyph"], a["name"])
            )
        else:
            tiles += (
                '<span class="tile soon">'
                '<span class="g">%s</span><span class="n">%s</span>'
                '<span class="badge">soon</span></span>'
                % (a["glyph"], a["name"])
            )
    return PAGE.replace("{{TILES}}", tiles)


PAGE = """<!doctype html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>GAIA</title>
<style>
  * { box-sizing:border-box; -webkit-tap-highlight-color:rgba(0,0,0,0); margin:0; padding:0; }
  body { background:#0a0c0e; color:#e8ebf0; font-family:-apple-system,Roboto,Helvetica,sans-serif;
         padding:14px; max-width:460px; margin:0 auto; -webkit-text-size-adjust:100%; }

  .head { padding:2px 2px 14px; }
  .head .dot { color:#35d0b6; font-size:20px; vertical-align:-2px; }
  .head .t { font-size:16px; font-weight:700; letter-spacing:.04em; margin-left:6px; }
  .head .s { color:#7d8794; font-size:12px; letter-spacing:.16em; text-transform:uppercase;
             display:block; margin:5px 0 0 2px; }

  .label { color:#7d8794; font-size:11px; letter-spacing:.14em; text-transform:uppercase;
           margin:16px 2px 8px; }

  /* app tiles — inline-block, no grid */
  .tiles { font-size:0; }
  .tile { display:inline-block; width:48%; vertical-align:top; height:74px; margin:0 0 3.5% 0;
          background:#14181d; border:1px solid #2a3038; border-radius:16px;
          text-align:center; position:relative; color:#e8ebf0; }
  .tile:nth-child(odd) { margin-right:4%; }
  .tile .g { display:block; font-size:22px; color:#35d0b6; margin:14px 0 2px; font-weight:700; }
  .tile .n { display:block; font-size:14px; font-weight:600; }
  .tile.soon { opacity:.4; }
  .tile.soon .g { color:#7d8794; }
  .tile .badge { position:absolute; top:8px; right:10px; font-size:9px; letter-spacing:.1em;
                 text-transform:uppercase; color:#7d8794; }
  button.tile:active { background:#35d0b6; border-color:#35d0b6; }
  button.tile:active .g, button.tile:active .n { color:#05120f; }

  /* rows of controls — inline-block cells */
  .row { font-size:0; margin-bottom:8px; }
  .row button { display:inline-block; width:32%; height:56px; font-size:16px; font-weight:600;
                background:#14181d; color:#e8ebf0; border:1px solid #2a3038; border-radius:14px;
                vertical-align:top; }
  .row button + button { margin-left:2%; }
  .row.two button { width:49%; }
  .row.two button + button { margin-left:2%; }
  .row.four button { width:23.5%; font-size:18px; }
  .row.four button + button { margin-left:2%; }
  .row button:active { background:#35d0b6; border-color:#35d0b6; color:#05120f; }

  /* d-pad — 3 cols inline-block, center is OK */
  .pad { font-size:0; margin:6px 0 4px; }
  .pad .c { display:inline-block; width:33.33%; height:64px; vertical-align:top; }
  .pad button { width:100%; height:100%; font-size:22px; background:#14181d; color:#e8ebf0;
                border:1px solid #2a3038; border-radius:14px; }
  .pad button.ok { background:#1b2026; font-size:16px; font-weight:700; }
  .pad button:active { background:#35d0b6; border-color:#35d0b6; color:#05120f; }
  .pad .c.blank { visibility:hidden; }

  .foot { margin-top:14px; }
</style></head><body>

  <div class="head">
    <span class="dot">&#9673;</span><span class="t">GAIA</span>
    <span class="s">Living Room</span>
  </div>

  <div class="label">Apps</div>
  <div class="tiles">{{TILES}}</div>

  <div class="label">Navigate</div>
  <div class="pad">
    <span class="c blank"><button>.</button></span>
    <span class="c"><button onclick="tap(this);post('/key/KEY_UP')">&#9650;</button></span>
    <span class="c blank"><button>.</button></span>
    <span class="c"><button onclick="tap(this);post('/key/KEY_LEFT')">&#9664;</button></span>
    <span class="c"><button class="ok" onclick="tap(this);post('/key/KEY_ENTER')">OK</button></span>
    <span class="c"><button onclick="tap(this);post('/key/KEY_RIGHT')">&#9654;</button></span>
    <span class="c blank"><button>.</button></span>
    <span class="c"><button onclick="tap(this);post('/key/KEY_DOWN')">&#9660;</button></span>
    <span class="c blank"><button>.</button></span>
  </div>
  <div class="row">
    <button onclick="tap(this);post('/key/KEY_RETURN')">&#8617; Back</button>
    <button onclick="tap(this);post('/key/KEY_HOME')">&#8962; Home</button>
    <button onclick="tap(this);post('/key/KEY_MUTE')">Mute</button>
  </div>
  <div class="row two">
    <button onclick="tap(this);post('/key/KEY_SOURCE')">Source</button>
    <button onclick="tap(this);post('/key/KEY_MENU')">Menu</button>
  </div>

  <div class="label">Volume &amp; Playback</div>
  <div class="row two">
    <button onclick="tap(this);post('/key/KEY_VOLDOWN')">Vol &minus;</button>
    <button onclick="tap(this);post('/key/KEY_VOLUP')">Vol &#43;</button>
  </div>
  <div class="row four">
    <button onclick="tap(this);post('/key/KEY_REWIND')">&#9664;&#9664;</button>
    <button onclick="tap(this);post('/key/KEY_PLAY')">&#9654;</button>
    <button onclick="tap(this);post('/key/KEY_PAUSE')">&#8214;</button>
    <button onclick="tap(this);post('/key/KEY_FF')">&#9654;&#9654;</button>
  </div>

  <div class="label">Power</div>
  <div class="row two foot">
    <button onclick="tap(this);post('/key/KEY_POWER')">Power</button>
    <button onclick="tap(this);post('/wake')">Wake</button>
  </div>

<script>
/* XMLHttpRequest, not fetch() — the 2012 Fire HD browser predates fetch. */
function post(path) {
  try { if (navigator.vibrate) navigator.vibrate(8); } catch (e) {}
  try { var x = new XMLHttpRequest(); x.open('POST', path, true); x.send(); } catch (e) {}
}
function tap(el) {
  /* brief visual confirm even if :active doesn't stick on old touch browsers */
  try {
    el.style.background = '#35d0b6';
    setTimeout(function () { el.style.background = ''; }, 120);
  } catch (e) {}
}
</script>
</body></html>"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
