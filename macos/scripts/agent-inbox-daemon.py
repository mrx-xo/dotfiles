#!/usr/bin/env python3
"""agent-inbox daemon: long-poll a Telegram bot, drop the user's images into ~/agent-inbox.

Design (see ~/.dotfiles/docs/phone-screenshot-ez-send.md):
- Dumb transport only: no knowledge of Emacs/ACP. Writes complete image files
  into INBOX via atomic temp-write + os.replace so watchers never see partials.
- Allowlist of one chat id: every other sender is dropped.
- Pure stdlib (urllib) on purpose — runs under /usr/bin/python3 with no venv.

The bot token comes from the macOS Keychain (service "agent-inbox-token"),
falling back to the TELEGRAM_BOT_TOKEN env var or ~/.config/agent-inbox/env
(chmod 600, KEY=VALUE lines). The chat ID isn't a secret and comes from the
env var or env file.
"""
import json
import logging
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

INBOX = pathlib.Path(os.path.expanduser("~/agent-inbox"))
OFFSET_F = INBOX / ".offset"
ENV_FILE = pathlib.Path(os.path.expanduser("~/.config/agent-inbox/env"))
POLL_TIMEOUT = 50  # seconds Telegram holds the getUpdates connection

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("agent-inbox")


def keychain_token():
    """Bot token from the login Keychain, or None if absent/unavailable."""
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", "agent-inbox-token", "-w"],
            capture_output=True, text=True, timeout=10)
        return out.stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def load_config():
    """Merged config dict: environment first, then ENV_FILE lines."""
    env = dict(os.environ)
    if ENV_FILE.is_file():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                env.setdefault(key.strip(), val.strip())
    return env


def load_secrets(env):
    """Return (token, allowed_chat_id): Keychain first, then env/ENV_FILE."""
    token = keychain_token() or env.get("TELEGRAM_BOT_TOKEN")
    if not token:
        sys.exit(f"no bot token: add to Keychain (service agent-inbox-token), "
                 f"the environment, or {ENV_FILE}")
    try:
        return token, int(env["TELEGRAM_ALLOWED_CHAT_ID"])
    except (KeyError, ValueError):
        sys.exit(f"missing/invalid TELEGRAM_ALLOWED_CHAT_ID: "
                 f"set it in the environment or {ENV_FILE}")


_CONFIG = load_config()
TOKEN, ALLOWED = load_secrets(_CONFIG)
# Screenshots can contain secrets; don't hoard them forever. 0 disables.
RETENTION_DAYS = int(_CONFIG.get("AGENT_INBOX_RETENTION_DAYS", "7"))
SWEEP_INTERVAL = 3600  # seconds between retention sweeps
API = f"https://api.telegram.org/bot{TOKEN}"
FILE_API = f"https://api.telegram.org/file/bot{TOKEN}"


def api_get(method, params, timeout):
    url = f"{API}/{method}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.load(resp)


def load_offset():
    try:
        return int(OFFSET_F.read_text().strip())
    except (OSError, ValueError):
        return 0


def save_offset(n):
    OFFSET_F.write_text(str(n))


def pick_file(msg):
    """Prefer an uncompressed image document; fall back to the largest photo size."""
    doc = msg.get("document")
    if doc and str(doc.get("mime_type", "")).startswith("image/"):
        ext = os.path.splitext(doc.get("file_name", ""))[1] or ".png"
        return doc["file_id"], ext
    photos = msg.get("photo")
    if photos:
        return photos[-1]["file_id"], ".jpg"  # last = largest
    return None, None


def ack(message_id, text):
    """Reply in the chat so the phone confirms delivery. Best-effort only."""
    try:
        api_get("sendMessage",
                {"chat_id": ALLOWED, "text": text,
                 "reply_to_message_id": message_id},
                timeout=30)
    except Exception as e:
        log.warning("ack failed: %s", e)


def sweep():
    """Delete inbox images older than RETENTION_DAYS and day-old stale temps.
    Never touches .offset (dotfile, but explicitly guarded anyway)."""
    now = time.time()
    removed = 0
    for f in INBOX.iterdir():
        if not f.is_file() or f == OFFSET_F:
            continue
        try:
            age = now - f.stat().st_mtime
            if f.name.startswith(".tmp-") and age > 86400:
                f.unlink()
                removed += 1
            elif (RETENTION_DAYS > 0 and not f.name.startswith(".")
                  and age > RETENTION_DAYS * 86400):
                f.unlink()
                removed += 1
        except OSError as e:
            log.warning("sweep: could not remove %s: %s", f.name, e)
    if removed:
        log.info("sweep: removed %d file(s) older than %dd", removed, RETENTION_DAYS)


def download(file_id, ext):
    meta = api_get("getFile", {"file_id": file_id}, timeout=60)
    file_path = meta["result"]["file_path"]
    with urllib.request.urlopen(f"{FILE_API}/{file_path}", timeout=120) as resp:
        data = resp.read()
    tmp = INBOX / f".tmp-{uuid.uuid4().hex}"
    tmp.write_bytes(data)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    final = INBOX / f"{stamp}-{uuid.uuid4().hex[:6]}{ext}"
    os.replace(tmp, final)  # atomic on same filesystem
    log.info("saved %s (%d bytes)", final.name, len(data))
    return final


def main():
    INBOX.mkdir(parents=True, exist_ok=True)
    offset = load_offset()
    last_sweep = 0.0
    log.info("started; offset=%s inbox=%s allowed_chat=%s retention=%dd",
             offset, INBOX, ALLOWED, RETENTION_DAYS)
    while True:
        try:
            if time.time() - last_sweep > SWEEP_INTERVAL:
                sweep()
                last_sweep = time.time()
            r = api_get("getUpdates",
                        {"timeout": POLL_TIMEOUT, "offset": offset + 1,
                         "allowed_updates": json.dumps(["message"])},
                        timeout=POLL_TIMEOUT + 20)
            for upd in r.get("result", []):
                offset = max(offset, upd["update_id"])
                # Saved before download: a crash mid-download skips that image
                # (re-send it) rather than looping on the same update forever.
                save_offset(offset)
                msg = upd.get("message") or {}
                chat_id = msg.get("chat", {}).get("id")
                if chat_id != ALLOWED:  # allowlist of one
                    log.warning("dropping update from chat %s", chat_id)
                    continue
                file_id, ext = pick_file(msg)
                if file_id:
                    final = download(file_id, ext)
                    ack(msg.get("message_id"), f"✓ {final.name}")
        except urllib.error.HTTPError as e:
            if e.code == 409:
                log.error("409 from getUpdates: a webhook is set on this bot; "
                          "run deleteWebhook once. Backing off 30s.")
                time.sleep(30)
            else:
                log.warning("HTTP error: %s (backing off)", e)
                time.sleep(5)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as e:
            log.warning("transient error: %s (backing off)", e)
            time.sleep(5)


if __name__ == "__main__":
    main()
