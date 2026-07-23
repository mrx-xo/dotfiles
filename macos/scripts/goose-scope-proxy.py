#!/usr/bin/env python3
"""goose-scope: a transparent logging proxy for Ollama.

    goose / DIY-agent / CLI  ──▶  127.0.0.1:11435 (this)  ──▶  Ollama upstream

Everything a local agent sends to Ollama funnels through here, so we get a
single, complete, structured record of "where it sends what / how long it
took" — regardless of which client made the call. One NDJSON event is written
per /api/chat and /api/generate request; every other path is proxied silently.

The Emacs `*goose-scope*` panel tails the NDJSON file and renders per-turn
timelines from it.

Env knobs:
  GOOSE_SCOPE_UPSTREAM  where the real Ollama lives   (default http://vengeance:11434;
                        set http://mrx2:11434 to fall back to the Air)
  GOOSE_SCOPE_PORT      local listen port             (default 11435)
  GOOSE_SCOPE_LOG       NDJSON output path            (default ~/.local/state/goose-scope/events.ndjson)
"""
import http.server
import http.client
import json
import os
import sys
import time
import threading
from urllib.parse import urlparse

UPSTREAM = os.environ.get("GOOSE_SCOPE_UPSTREAM", "http://vengeance:11434")
LISTEN_PORT = int(os.environ.get("GOOSE_SCOPE_PORT", "11435"))
LOG_PATH = os.environ.get(
    "GOOSE_SCOPE_LOG",
    os.path.expanduser("~/.local/state/goose-scope/events.ndjson"),
)

_up = urlparse(UPSTREAM)
_up_host = _up.hostname
_up_port = _up.port or 80
_loglock = threading.Lock()

# Hop-by-hop headers we must NOT forward verbatim (RFC 7230 §6.1) plus the
# framing headers we set ourselves.
_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "content-length",
}


def _ensure_logdir():
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)


def log_event(ev):
    """Append one NDJSON event. Never let logging break the proxy."""
    try:
        line = json.dumps(ev, ensure_ascii=False)
        with _loglock:
            with open(LOG_PATH, "a") as f:
                f.write(line + "\n")
    except Exception as e:  # noqa: BLE001 - logging must never crash a request
        print(f"[goose-scope] log error: {e}", file=sys.stderr)


def ns_ms(x):
    """Nanoseconds -> milliseconds (rounded), or None."""
    return round(x / 1e6, 1) if isinstance(x, (int, float)) else None


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # silence default access logging
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(length) if length else b""

    def _req_meta(self, body):
        """Pull the interesting bits out of an /api/chat|generate request."""
        try:
            j = json.loads(body)
        except Exception:
            return {}
        msgs = j.get("messages", []) or []
        last_user = next(
            (m.get("content", "") for m in reversed(msgs) if m.get("role") == "user"),
            "",
        )
        # /api/generate uses "prompt" instead of messages
        if not last_user:
            last_user = j.get("prompt", "") or ""
        return {
            "model": j.get("model"),
            "n_messages": len(msgs),
            "n_tools": len(j.get("tools", []) or []),
            "think": j.get("think"),
            "last_user": (last_user or "")[:200],
        }

    def _proxy(self):
        body = self._read_body()
        if os.environ.get("GOOSE_SCOPE_DEBUG"):
            print(f"[goose-scope] {self.command} {self.path}", file=sys.stderr)
        interesting = self.path in ("/api/chat", "/api/generate",
                                    "/v1/chat/completions", "/v1/completions")
        req_meta = self._req_meta(body) if (interesting and body) else {}
        t0 = time.time()

        conn = http.client.HTTPConnection(_up_host, _up_port, timeout=600)
        try:
            fwd_headers = {
                k: v for k, v in self.headers.items() if k.lower() != "host"
            }
            conn.request(self.command, self.path, body=body, headers=fwd_headers)
            resp = conn.getresponse()
        except Exception as e:  # noqa: BLE001
            try:
                self.send_error(502, f"goose-scope upstream error: {e}")
            except Exception:
                pass
            if interesting:
                log_event({"ts": t0, "kind": "error", "path": self.path,
                           "error": str(e), **req_meta})
            conn.close()
            return

        # Relay status + headers. We always re-frame the body as chunked so we
        # can stream both streaming (NDJSON) and plain responses uniformly while
        # teeing the bytes for parsing.
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in _HOP:
                continue
            self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        native_final = None   # last Ollama-native object (has nanosecond timings)
        oai_model = None      # model from OpenAI-compat (/v1) chunks
        oai_usage = None      # {prompt_tokens, completion_tokens}
        tool_seen = False
        buf = b""

        def absorb(obj):
            """Fold one parsed JSON object into the running summary."""
            nonlocal native_final, oai_model, oai_usage, tool_seen
            if not isinstance(obj, dict):
                return
            if "choices" in obj:  # OpenAI-compat (/v1)
                oai_model = obj.get("model") or oai_model
                for ch in obj.get("choices", []):
                    d = ch.get("delta") or ch.get("message") or {}
                    if d.get("tool_calls"):
                        tool_seen = True
                if obj.get("usage"):
                    oai_usage = obj["usage"]
            else:                 # Ollama-native (/api)
                native_final = obj
                if obj.get("message", {}).get("tool_calls"):
                    tool_seen = True

        try:
            while True:
                chunk = resp.read(4096)
                if not chunk:
                    break
                self.wfile.write(f"{len(chunk):X}\r\n".encode() + chunk + b"\r\n")
                if interesting:
                    buf += chunk
                    # /api streams newline-delimited JSON; /v1 streams
                    # `data: {...}` SSE lines ending in `data: [DONE]`.
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        line = line.strip()
                        if line.startswith(b"data:"):
                            line = line[5:].strip()
                        if not line or line == b"[DONE]":
                            continue
                        try:
                            absorb(json.loads(line))
                        except Exception:
                            continue
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except Exception as e:  # noqa: BLE001 - client hung up, etc.
            print(f"[goose-scope] relay error: {e}", file=sys.stderr)
        finally:
            conn.close()

        if not interesting:
            return

        # Non-streaming responses arrive as one JSON object (no trailing \n).
        if native_final is None and oai_model is None and buf.strip():
            try:
                absorb(json.loads(buf))
            except Exception:
                pass

        try:
            wall_ms = round((time.time() - t0) * 1000, 1)
            if native_final is not None:  # Ollama-native: rich timing breakdown
                f = native_final
                ec, ed = f.get("eval_count"), f.get("eval_duration")
                ev = {
                    "api": "ollama",
                    "model": f.get("model") or req_meta.get("model"),
                    "prompt_tokens": f.get("prompt_eval_count"),
                    "output_tokens": ec,
                    "load_ms": ns_ms(f.get("load_duration")),
                    "prompt_ms": ns_ms(f.get("prompt_eval_duration")),
                    "eval_ms": ns_ms(f.get("eval_duration")),
                    "total_ms": ns_ms(f.get("total_duration")),
                    "tok_s": round(ec / (ed / 1e9), 1) if ec and ed else None,
                }
            else:                     # OpenAI-compat: only usage + wall time
                u = oai_usage or {}
                otok = u.get("completion_tokens")
                ev = {
                    "api": "openai",
                    "model": oai_model or req_meta.get("model"),
                    "prompt_tokens": u.get("prompt_tokens"),
                    "output_tokens": otok,
                    "load_ms": None,
                    "prompt_ms": None,
                    "eval_ms": None,
                    "total_ms": None,
                    "tok_s": (round(otok / (wall_ms / 1000.0), 1)
                              if otok and wall_ms else None),
                }
            ev.update({
                "ts": t0,
                "wall_ms": wall_ms,
                "path": self.path,
                "n_tools": req_meta.get("n_tools"),
                "think": req_meta.get("think"),
                "last_user": req_meta.get("last_user"),
                "tool_call": bool(tool_seen),
            })
            log_event(ev)
        except Exception:
            import traceback
            print("[goose-scope] EVENT BUILD ERROR:\n" + traceback.format_exc(),
                  file=sys.stderr, flush=True)

    # Ollama uses GET (tags/ps), POST (chat/generate/show), DELETE, etc.
    do_GET = _proxy
    do_POST = _proxy
    do_PUT = _proxy
    do_DELETE = _proxy
    do_HEAD = _proxy


class ThreadingServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    try:
        sys.stderr.reconfigure(line_buffering=True)  # flush debug per line
    except Exception:
        pass
    _ensure_logdir()
    srv = ThreadingServer(("127.0.0.1", LISTEN_PORT), Handler)
    print(f"[goose-scope] listening 127.0.0.1:{LISTEN_PORT} -> {UPSTREAM}",
          file=sys.stderr)
    print(f"[goose-scope] logging -> {LOG_PATH}", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[goose-scope] bye", file=sys.stderr)


if __name__ == "__main__":
    main()
