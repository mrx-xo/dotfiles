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


def load_secrets():
    """Return (token, allowed_chat_id): Keychain first, then env, then ENV_FILE."""
    env = dict(os.environ)
    if ENV_FILE.is_file():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                env.setdefault(key.strip(), val.strip())
    token = keychain_token() or env.get("TELEGRAM_BOT_TOKEN")
    if not token:
        sys.exit(f"no bot token: add to Keychain (service agent-inbox-token), "
                 f"the environment, or {ENV_FILE}")
    try:
        return token, int(env["TELEGRAM_ALLOWED_CHAT_ID"])
    except (KeyError, ValueError):
        sys.exit(f"missing/invalid TELEGRAM_ALLOWED_CHAT_ID: "
                 f"set it in the environment or {ENV_FILE}")


TOKEN, ALLOWED = load_secrets()
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
    log.info("started; offset=%s inbox=%s allowed_chat=%s", offset, INBOX, ALLOWED)
    while True:
        try:
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
                    download(file_id, ext)
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
