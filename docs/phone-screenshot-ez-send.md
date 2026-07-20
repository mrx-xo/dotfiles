# Phone screenshot → Emacs `agent-shell` — Implementation Plan

**Status: PLAN TO REVIEW — not shipped code.** Code blocks are sketches meant to be
read, criticized, and refined before anything is built. Line numbers cited for
`agent-shell.el` are from `main` as of July 2026 and should be re-checked against your
installed version before implementation.

---

## 1. Executive summary

Goal: take a screenshot on the phone, and have it land inside a *specific*
`agent-shell` buffer as an image attached to the next agent turn — with the minimum
possible ceremony.

The single most important finding, and the one the whole plan rests on:

> **`agent-shell` already has first-class image-attachment support, and the public
> Lisp entry point `agent-shell-insert` can attach an image file to a chosen buffer's
> pending prompt programmatically.** An attachment is, mechanically, nothing more than
> an `@/absolute/path.png` token inserted into the shell's input area. At submit time
> `agent-shell` parses `@`-mentions and turns image files into ACP `image` content
> blocks (base64 `data` + `mimeType`) automatically, provided the agent advertised the
> `image` prompt capability (Claude Agent, Gemini, etc. all do).

That means the Emacs side does **not** need to touch ACP, acp.el, base64, or content
blocks at all. It needs to insert one line of text into the right buffer. This is a
much smaller, much safer surface than the original brief assumed, and it makes the
"Emacs is the brain, daemon is dumb" architecture even cleaner.

The rest of the system is exactly as you designed it: a Telegram bot as transport, a
dumb local daemon that long-polls and drops photos into an inbox folder using an
atomic download-and-rename, and an "arm from the buffer" flow in Emacs that watches
the inbox once and attaches the next arriving image to the armed buffer.

One design change I do recommend: on macOS, **make directory polling the primary
inbox-watch mechanism, with `file-notify` as an optional fast path**, because Emacs's
default macOS notification backend (kqueue) is documented to not reliably report new
files appearing in a watched directory. Details in §8.1 — this is the one place the
original design has a real technical risk.

---

## 2. Architecture overview & data flow

```
┌─────────────┐   photo    ┌──────────────────┐  getUpdates (long poll)  ┌──────────────┐
│   Phone     │ ─────────► │  Telegram cloud  │ ◄──────────────────────  │  Mac daemon  │
│ Telegram app│            │  (your bot)      │  ──── Update{photo} ───►  │ (Python,     │
└─────────────┘            └──────────────────┘   getFile + file DL       │  launchd)    │
                                                                          └──────┬───────┘
                                                              atomic write+rename │
                                                                                  ▼
                                                                    ┌───────────────────────┐
                                                                    │  ~/agent-inbox/        │
                                                                    │   .tmp-abc123  (temp)  │
                                                                    │   20260718-143205.png  │ ◄── final name
                                                                    └───────────┬────────────┘
                                                                                │ create event / poll hit
                                                                                ▼
        user hits keybind in a specific        ┌────────────────────────────────────────────┐
        agent-shell buffer  ───────────────►   │  Emacs: agent-shell-inbox one-shot watcher   │
        (this "arms" the watcher, capturing     │  armed → next image → agent-shell-insert     │
         the target buffer)                     │  :text "@<path>" :shell-buffer <armed-buf>   │
                                                └───────────────────┬──────────────────────────┘
                                                                    ▼
                                             `@<path>` text lands in the armed buffer's input.
                                             On submit, agent-shell builds an ACP `image`
                                             content block (base64) and sends the turn.
```

**End-to-end sequence**

1. In the `agent-shell` buffer you want the image in, you press the arm keybind
   (suggested `C-c C-i`, mnemonic "image"). Emacs records that buffer as the target and
   starts a *one-shot* inbox watcher (poll and/or `file-notify`). A mode-line indicator
   shows "armed", and a timeout timer is started.
2. You take/share a screenshot from the phone to your bot.
3. The daemon's long-poll returns an `Update` containing a `photo`. It calls `getFile`,
   downloads the largest photo size to `~/agent-inbox/.tmp-<rand>`, then `os.rename`s it
   to `~/agent-inbox/<timestamp>.png` (atomic, same filesystem).
4. The Emacs watcher sees the new `*.png` (ignoring dot/temp files), disarms itself,
   cancels the timeout, and calls
   `agent-shell-insert :text "@<abs-path>" :shell-buffer <armed-buffer> :no-focus t`.
5. The `@path` token (with an inline thumbnail) is now in the armed buffer's input. You
   type any accompanying prompt text and press `RET`. `agent-shell` submits the turn; its
   `agent-shell--build-content-blocks` converts the image into an ACP `image` block.

**Trust boundary:** the only thing crossing from the internet into your machine is an
image file written into one folder. The daemon has no knowledge of Emacs, buffers, or
ACP. Emacs never talks to Telegram. This keeps each component individually auditable.

---

## 3. Validation of the settled design decisions

- **Telegram over AirDrop.** Correct. AirDrop has no scripting/trigger surface — you
  cannot get a file-received event or a stable landing path programmatically, so you
  can't build the "next image arrives → attach" trigger. Telegram gives you a clean,
  pollable API and a well-defined download step. Endorsed.
- **Telegram over Discord.** Correct for this use case. Discord would work but adds a
  heavier bot model and gateway/websocket complexity for zero benefit here; Telegram's
  `getUpdates` long-poll is the lightest possible "pull new photos" loop and needs no
  public endpoint. Endorsed.
- **No webhook / no port-forwarding.** Correct. `getUpdates` long-polling is explicitly
  the alternative to webhooks and requires no inbound connectivity. (You cannot use both
  at once — if a webhook is ever set on the bot, `getUpdates` returns a 409 until you
  `deleteWebhook`. Noted as a gotcha, not a design change.)
- **Emacs is the brain, daemon is dumb.** Strongly endorsed, and now even more so: the
  daemon only writes files; all buffer/attachment logic is a few lines of Elisp on top of
  a public `agent-shell` API. The daemon never needs to know a buffer exists.
- **Arm-from-buffer one-shot watch.** Endorsed as the right UX. The only implementation
  caveat is the watch *mechanism* on macOS (§8.1): prefer polling, treat `file-notify` as
  an optimization.
- **Atomic download-and-rename.** Endorsed and essential — it's what lets the watcher
  treat "a new `*.png` appeared" as "a complete file is ready", with no partial-file
  race. Keep it.
- **Mode-line indicator + timeout on armed state.** Endorsed; both are cheap and prevent
  the confusing "I armed it an hour ago and forgot" state.

---

## 4. THE VERIFIED ATTACH MECHANISM (the centerpiece)

This section is the part the brief flagged as make-or-break. It is answered from the
actual `agent-shell.el` and `acp.el` source, not inference.

### 4.1 What a "prompt attachment" actually is

There is **no attachment object, no buffer-local attachment list, and no ACP content
block created at attach time.** An attachment is an **`@path` text token inserted into
the comint input** (the pending prompt). For images, that text additionally carries a
`display` image property so a thumbnail previews inline, plus an
`agent-shell-context-image` property so that deleting any part of the token removes the
whole thumbnail. The load-bearing content is the literal text `@/abs/path`.

The interactive commands you already saw in the README —
`agent-shell-send-file` / `agent-shell-insert-file` (a `defalias` of the former) /
`agent-shell-send-screenshot` / `agent-shell-send-clipboard-image` — are thin wrappers.
They compute the display text and call one public inserter. For example
(`agent-shell.el` ~L7302, verbatim):

```elisp
(defun agent-shell-send-screenshot (&optional pick-shell)
  ...
  (let* ((screenshots-dir (agent-shell--dot-subdir "screenshots"))
         (screenshot-path (agent-shell--capture-screenshot :destination-dir screenshots-dir))
         (shell-buffer (when pick-shell
                         (agent-shell--read-shell-buffer :prompt "Send screenshot to shell: "))))
    (agent-shell-insert
     :text (agent-shell--get-files-context :files (list screenshot-path))
     :shell-buffer shell-buffer)))
```

Note it writes a real PNG to disk first, then inserts `@<path>` for it. `agent-shell-send-clipboard-image`
is identical but sources the PNG from the clipboard via `pngpaste` (macOS). Crucially,
neither passes `:submit`, so they insert and stop — the user still presses `RET`. That
is exactly the behavior we want for our flow.

### 4.2 How `@path` becomes an ACP image block (at submit)

At submit, `agent-shell--send-command` (~L6801) builds content blocks transiently and
calls `acp-make-session-prompt-request`:

```elisp
(let* ((content-blocks (condition-case nil
                           (agent-shell--build-content-blocks expanded-prompt)
                         (error `[((type . "text") (text . ,(substring-no-properties expanded-prompt)))]))))
  ...
  (acp-make-session-prompt-request
   :session-id (map-nested-elt agent-shell--state '(:session :id))
   :prompt content-blocks))
```

`agent-shell--build-content-blocks` (~L6456) parses `@`-mentions and, per file, chooses
the block type (verbatim, the image branch):

```elisp
;; Binary image and image capability supported -> ContentBlock::Image
((and supports-image (map-elt file :base64-p)
      (string-prefix-p "image/" (map-elt file :mime-type)))
 (push `((type . "image")
         (data . ,(map-elt file :content))      ; base64 string
         (mimeType . ,(map-elt file :mime-type))
         (uri . ,(concat "file://" resolved-path)))
       content-blocks))
```

Selection logic to internalize:

- **An image file (binary + `image/*` mime) always becomes a base64 `image` block when
  the agent advertised the `image` prompt capability** — independent of
  `agent-shell-embed-file-size-limit`.
- `agent-shell-embed-file-size-limit` (default 102400 bytes) only governs *non-image*
  files: under the limit → embedded `resource` block; over it → `resource_link` (path
  only). Irrelevant to our screenshot path, but good to know.
- Capability comes from the ACP handshake. `acp.el`'s README documents the Gemini
  handshake returning `agentCapabilities … (promptCapabilities (image . t) …)`, and
  `agent-shell` stores it at `(:prompt-capabilities :image)` in `agent-shell--state`.
  Claude Agent via `claude-agent-acp` advertises image support too. If a given agent
  did *not* advertise image support, the same file silently degrades to a `resource` /
  `resource_link` — no error, just no inline image. Worth a one-time manual check per
  agent via the traffic viewer (§9).

The upshot: **we insert `@path`; agent-shell does all the ACP/base64 work at submit.**

### 4.3 Buffer targeting — how to hit a *specific* buffer

The insert path accepts an explicit `:shell-buffer`. `agent-shell-insert` (public
`cl-defun`, ~L7988) has this signature:

```elisp
(cl-defun agent-shell-insert (&key text submit no-focus shell-buffer) ...)
```

Its worker `agent-shell--insert-to-shell-buffer` (~L7927) honors the target:

```elisp
(let* ((shell-buffer (or shell-buffer (agent-shell--shell-buffer :no-create t))))
  ...
  (with-current-buffer shell-buffer
    (when (shell-maker-busy) (user-error "Busy, try later"))
    ...
    (insert text)
    ...
    (when submit (shell-maker-submit))))
```

When no buffer is passed, it resolves via `agent-shell--shell-buffer` (viewport →
current `agent-shell-mode` buffer → first shell in current project → else create). For
us, that default is *not* good enough — we want the buffer that was armed, which may not
be current when the image lands. So we **capture the buffer object at arm time** and pass
it explicitly. This is the key to making "arm from buffer" reliable.

### 4.4 The single cleanest programmatic entry point (recommended)

```elisp
;; Attach the image to a specific buffer's pending prompt, WITHOUT submitting.
(agent-shell-insert
 :text (concat "@" (expand-file-name image-path))
 :shell-buffer target-buffer
 :no-focus t)
```

To reproduce the exact inline-thumbnail behavior of the interactive commands, generate
the text with the private helper instead of hand-building `@path`:

```elisp
(agent-shell-insert
 :text (agent-shell--get-files-context :files (list image-path))
 :shell-buffer target-buffer
 :no-focus t)
```

`agent-shell--get-files-context` is "private" (double-dash) but is the exact call the
shipping commands use; using it is low-risk and gives you the thumbnail. If you prefer to
depend only on the fully public surface, the bare `(concat "@" path)` form works
identically for ACP purposes (same `@`-mention parse), just without the inline preview.

**Do not pass `:submit t`** in the MVP. Leaving submission to the user lets them add a
sentence ("what's wrong with this layout?") before sending, and avoids firing a turn into
a busy shell.

### 4.5 Fallback, clearly labeled

There is **no** public "here is a content block, attach it" API — content blocks are
built only at submit from `@`-mentions, and `acp.el` ships no content-block
constructors. So the realistic options are:

- **Primary (recommended):** `agent-shell-insert :text "@<path>" :shell-buffer BUF` — the
  sanctioned wrapper around the exact code path the interactive commands use.
- **Fallback A (equivalent, lower-level):** replicate the worker: `with-current-buffer BUF`,
  guard on `(shell-maker-busy)`, `goto-char (point-max)`, `insert "@<path>"`. This is what
  `agent-shell--insert-to-shell-buffer` does; use it only if the public wrapper's signature
  changes.
- **Fallback B (do not use unless forced):** drive `acp-make-session-prompt-request` +
  `agent-shell--send-request` yourself with a hand-built `image` block. This bypasses the
  input buffer entirely and is brittle against internal refactors. Documented only for
  completeness.

Caveats to bake into the code:

- `@`-mention parsing splits on whitespace; a path containing spaces must be inserted as
  `@"…"`. `agent-shell--get-files-context` does *not* quote. **Keep the inbox path
  space-free** (e.g. `~/agent-inbox`) to sidestep this entirely; if you can't, insert
  `(concat "@\"" path "\"")` yourself.
- `agent-shell-insert` raises `user-error "Busy, try later"` if the shell is mid-turn.
  The arm command should therefore attach when the shell is idle; if busy, either defer or
  tell the user. (agent-shell itself defers when the *session* isn't initialized yet, via
  a `prompt-ready` subscription, but the *busy* case is a hard error to handle.)

---

## 5. Component build — Telegram bot

### 5.1 BotFather setup (one time)

1. In Telegram, open **@BotFather** → `/newbot` → give it a name and a unique
   `@username`. BotFather returns a **bot token** like `123456789:AA...`. Treat this
   token like a password — anyone with it controls the bot.
2. (Optional but recommended) `/setprivacy` → **Enable** privacy so the bot only receives
   messages directed at it (irrelevant for 1:1 DMs, matters if you ever add it to a
   group). For DM-only screenshot use, default is fine.
3. Send your bot a message ("hi") from your phone once so a chat exists.

### 5.2 Find and pin your own chat ID (security-critical)

The daemon must accept photos **only** from your own Telegram account. Get your numeric
chat ID once:

- Call `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser after you've DM'd
  the bot, and read `result[].message.chat.id`. That integer is your allowlist of one.

Hard-code / config that ID; the daemon drops any update whose `message.chat.id` doesn't
match. This is the primary defense against a stranger who guesses/leaks your bot username
spamming images into your inbox.

### 5.3 API mechanics this daemon uses

- **`getUpdates` (long polling).** `GET /bot<TOKEN>/getUpdates?timeout=50&offset=<n>&allowed_updates=["message"]`.
  The `timeout` makes the server hold the connection up to 50s until an update exists
  (efficient — not a busy loop). `offset` = last processed `update_id + 1`; sending it
  acknowledges everything before it so you never re-see old updates. Pass
  `allowed_updates=["message"]` explicitly on first boot to ignore everything else (note:
  omitting it *preserves the previous server-side setting*, so set it explicitly).
- **Webhook mutual exclusion.** You cannot long-poll while a webhook is set; if you ever
  get HTTP 409, call `deleteWebhook` once. We never set a webhook, so this is just a
  guard.
- **`getFile` + download.** A photo update carries a `photo` array of `PhotoSize`
  objects (thumbnails → full size); take the **last** element (largest) and its
  `file_id`. Call `GET /bot<TOKEN>/getFile?file_id=<id>` to get a `file_path`, then
  download from `https://api.telegram.org/file/bot<TOKEN>/<file_path>`. Bots can download
  files up to **20 MB** via this route — fine for phone screenshots.
- **Photo vs document.** Telegram *recompresses* anything sent as a "photo" to JPEG. If
  you want pixel-exact PNG screenshots (sharp text), send the screenshot as a **file /
  document** in the Telegram app instead of as a photo; then the update carries a
  `document` with its own `file_id` and the original bytes are preserved. **Recommend the
  daemon handle both `message.photo` and `message.document` (image/*).** This is a small
  addition with a real quality payoff for screenshots of text.

---

## 6. Component build — the daemon (Python)

**Language:** Python 3 with only the standard library + `requests` (or pure `urllib` to
avoid any dependency). No framework needed.

**Inbox location:** `~/agent-inbox/` (space-free, per §4.5). Daemon `mkdir -p`s it on
start. Temp files as `~/agent-inbox/.tmp-<uuid>`; final files as
`~/agent-inbox/<UTC-timestamp>-<update_id>.png|jpg`.

**Config & secrets:** read `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_CHAT_ID` from the
environment (injected by launchd from a file `chmod 600`, or from the macOS Keychain via
`security find-generic-password` at start). **Never** hard-code the token in the script or
commit it. See §8.2.

**Offset persistence:** store the last `update_id` in `~/agent-inbox/.offset` so a daemon
restart doesn't reprocess old images (also avoids re-downloading after a crash).

### 6.1 Core loop (sketch — not final code)

```python
#!/usr/bin/env python3
"""agent-inbox daemon: long-poll a Telegram bot, drop the user's photos into ~/agent-inbox."""
import os, sys, time, uuid, json, logging, pathlib, urllib.parse, requests

TOKEN     = os.environ["TELEGRAM_BOT_TOKEN"]
ALLOWED   = int(os.environ["TELEGRAM_ALLOWED_CHAT_ID"])
INBOX     = pathlib.Path(os.path.expanduser("~/agent-inbox"))
API       = f"https://api.telegram.org/bot{TOKEN}"
FILE_API  = f"https://api.telegram.org/file/bot{TOKEN}"
OFFSET_F  = INBOX / ".offset"

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("agent-inbox")

def load_offset():
    try: return int(OFFSET_F.read_text().strip())
    except Exception: return 0

def save_offset(n): OFFSET_F.write_text(str(n))

def download(file_id, ext):
    meta = requests.get(f"{API}/getFile", params={"file_id": file_id}, timeout=60).json()
    file_path = meta["result"]["file_path"]
    data = requests.get(f"{FILE_API}/{file_path}", timeout=120).content
    tmp = INBOX / f".tmp-{uuid.uuid4().hex}"
    tmp.write_bytes(data)                                   # write to temp name
    final = INBOX / f"{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}-{uuid.uuid4().hex[:6]}{ext}"
    os.replace(tmp, final)                                  # atomic rename (same FS)
    log.info("saved %s (%d bytes)", final.name, len(data))
    return final

def pick_file(msg):
    # Prefer an uncompressed image document; fall back to the largest photo size.
    doc = msg.get("document")
    if doc and str(doc.get("mime_type", "")).startswith("image/"):
        ext = os.path.splitext(doc.get("file_name", ""))[1] or ".png"
        return doc["file_id"], ext
    photos = msg.get("photo")
    if photos:
        return photos[-1]["file_id"], ".jpg"               # last = largest
    return None, None

def main():
    INBOX.mkdir(parents=True, exist_ok=True)
    offset = load_offset()
    log.info("agent-inbox daemon started; offset=%s inbox=%s", offset, INBOX)
    while True:
        try:
            r = requests.get(f"{API}/getUpdates",
                             params={"timeout": 50, "offset": offset + 1,
                                     "allowed_updates": json.dumps(["message"])},
                             timeout=70).json()
            for upd in r.get("result", []):
                offset = max(offset, upd["update_id"])
                save_offset(offset)
                msg = upd.get("message") or {}
                if msg.get("chat", {}).get("id") != ALLOWED:      # allowlist of one
                    log.warning("dropping update from chat %s", msg.get("chat", {}).get("id"))
                    continue
                file_id, ext = pick_file(msg)
                if file_id:
                    download(file_id, ext)
        except requests.exceptions.RequestException as e:
            log.warning("network error: %s (backing off)", e)
            time.sleep(5)                                   # backoff on transient errors
        except Exception as e:
            log.exception("unexpected error: %s", e)
            time.sleep(5)

if __name__ == "__main__":
    main()
```

Notes / decisions embedded above:
- `os.replace` (not `os.rename`) is the atomic-rename call; it's atomic on the same
  filesystem, which is why temp and final both live in `~/agent-inbox`.
- Offset is saved *before* download so a crash mid-download doesn't loop on the same
  update forever (you'd lose that one image and can re-send). If you'd rather never lose an
  image, save the offset *after* successful download and accept possible reprocessing on
  crash — a deliberate trade-off to pick.
- Errors back off 5s and continue; the loop is meant to run forever under launchd.

---

## 7. Component build — launchd (auto-start on macOS)

Use a **LaunchAgent** (runs as your user, in your login session) rather than a
LaunchDaemon (root, no user session). File: `~/Library/LaunchAgents/com.marx.agent-inbox.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.marx.agent-inbox</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/marx/bin/agent-inbox-daemon.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TELEGRAM_BOT_TOKEN</key>        <string>__inject_or_load_from_keychain__</string>
    <key>TELEGRAM_ALLOWED_CHAT_ID</key>  <string>123456789</string>
  </dict>
  <key>RunAtLoad</key>        <true/>          <!-- start on login -->
  <key>KeepAlive</key>        <true/>          <!-- restart if it exits/crashes -->
  <key>StandardOutPath</key>  <string>/Users/marx/agent-inbox/daemon.log</string>
  <key>StandardErrorPath</key><string>/Users/marx/agent-inbox/daemon.err</string>
  <key>ProcessType</key>      <string>Background</string>
</dict>
</plist>
```

Load / manage:

```bash
launchctl load  -w ~/Library/LaunchAgents/com.marx.agent-inbox.plist   # enable + start
launchctl unload   ~/Library/LaunchAgents/com.marx.agent-inbox.plist   # stop + disable
# newer macOS equivalents:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.marx.agent-inbox.plist
launchctl kickstart -k gui/$(id -u)/com.marx.agent-inbox
```

Token-safety refinement (recommended over putting the token in the plist, which is
world-readable-ish and easy to leak in backups): keep the token in the **Keychain** and
have the daemon fetch it at startup with
`security find-generic-password -s agent-inbox-token -w`, so the plist only carries the
non-secret chat ID. Alternatively, `chmod 600` a small env file and have a wrapper
`source` it before exec. Either removes the secret from the plist.

launchd notes: `KeepAlive true` + `RunAtLoad true` gives you "start at login, restart on
crash." If the daemon exits too fast repeatedly, launchd throttles restarts to ~10s — fine
here. Logs land in `~/agent-inbox/daemon.log` / `.err`; rotate manually or add a
`newsyslog`/logrotate entry if they grow.

---

## 8. Component build — the Emacs side

The whole Emacs side is one small package, e.g. `agent-shell-inbox.el`. Public surface:
one arm command + one disarm command + a customizable inbox path and timeout.

### 8.1 Inbox-watch mechanism — the one real technical risk

**Do not rely solely on `file-notify` on macOS.** Emacs's default macOS notification
backend is **kqueue**, which (per the Emacs manual and long-standing reports) does *not*
reliably report new files appearing inside a *watched directory* — kqueue watches file
descriptors and does not surface per-entry create/rename inside a directory the way inotify
(Linux) or gfilenotify (glib) do. On a stock Homebrew/`emacs-plus` build, a
`file-notify-add-watch` on `~/agent-inbox` may simply never fire when the daemon renames a
file in.

Recommended approach — **poll by default, `file-notify` as an optional fast path**:

- **Primary: one-shot polling.** When armed, snapshot the current set of `*.png/*.jpg`
  files, then `run-with-timer` every ~1s to diff against the snapshot. First new file →
  attach + disarm. A 1s poll on a nearly-empty folder is negligible cost, is 100% portable,
  and neatly ignores dotfiles/temp files by extension filter. Given the armed window is
  short and user-initiated, polling is arguably *more* robust than notifications here.
- **Optional: `file-notify` fast path.** If `(file-notify-valid-p …)` works on the user's
  build (e.g. an Emacs compiled with gfilenotify, or if kqueue proves to fire for creates on
  their setup), use it to attach instantly and fall back to the poll timer as a safety net.
  Keep both; disarm cancels whichever fired first plus the other.

Either way the watch is **one-shot**: the first qualifying new file disarms everything.

### 8.2 Arm / attach / disarm (sketch — not final code)

```elisp
;;; agent-shell-inbox.el --- Attach phone screenshots into an armed agent-shell buffer

(require 'agent-shell)
(require 'filenotify)

(defcustom agent-shell-inbox-directory (expand-file-name "~/agent-inbox/")
  "Folder the daemon drops incoming screenshots into. Keep it space-free."
  :type 'directory)

(defcustom agent-shell-inbox-timeout 120
  "Seconds to stay armed before auto-disarming."
  :type 'integer)

(defcustom agent-shell-inbox-poll-interval 1.0
  "Polling interval (seconds) for the inbox watcher."
  :type 'number)

(defcustom agent-shell-inbox-image-regexp "\\.\\(png\\|jpe?g\\)\\'"
  "Only files matching this (and not dotfiles) are treated as incoming images."
  :type 'regexp)

(defvar agent-shell-inbox--armed-buffer nil "Target buffer when armed, else nil.")
(defvar agent-shell-inbox--poll-timer nil)
(defvar agent-shell-inbox--timeout-timer nil)
(defvar agent-shell-inbox--fn-descriptor nil)
(defvar agent-shell-inbox--seen nil "Snapshot of filenames at arm time.")

(defun agent-shell-inbox--images ()
  "Current qualifying image files in the inbox (absolute paths, no dotfiles)."
  (seq-filter (lambda (f)
                (and (not (string-prefix-p "." (file-name-nondirectory f)))
                     (string-match-p agent-shell-inbox-image-regexp f)))
              (directory-files agent-shell-inbox-directory t)))

(defun agent-shell-inbox--attach (image-path)
  "Attach IMAGE-PATH into the armed buffer's pending prompt, then disarm."
  (let ((buf agent-shell-inbox--armed-buffer))
    (agent-shell-inbox-disarm)                       ; disarm FIRST (idempotent, one-shot)
    (if (not (buffer-live-p buf))
        (message "agent-shell-inbox: armed buffer gone; %s left in inbox" image-path)
      (with-current-buffer buf
        (if (shell-maker-busy)
            (message "agent-shell-inbox: shell busy; %s left in inbox, attach manually"
                     image-path)
          ;; Public entry point. Use --get-files-context for the inline thumbnail,
          ;; or (concat "@" (expand-file-name image-path)) for public-only surface.
          (agent-shell-insert
           :text (agent-shell--get-files-context :files (list image-path))
           :shell-buffer buf
           :no-focus t)
          (message "agent-shell-inbox: attached %s" (file-name-nondirectory image-path)))))))

(defun agent-shell-inbox--poll ()
  (let* ((now (mapcar #'file-name-nondirectory (agent-shell-inbox--images)))
         (new (seq-difference now agent-shell-inbox--seen)))
    (when new
      (agent-shell-inbox--attach
       (expand-file-name (car (sort new #'string<)) agent-shell-inbox-directory)))))

(defun agent-shell-inbox--fn-callback (event)
  (pcase-let ((`(,_desc ,action ,file . ,_) event))
    (when (and (memq action '(created renamed))
               (not (string-prefix-p "." (file-name-nondirectory file)))
               (string-match-p agent-shell-inbox-image-regexp file))
      (agent-shell-inbox--attach file))))

;;;###autoload
(defun agent-shell-inbox-arm ()
  "Arm the inbox watcher against the CURRENT agent-shell buffer (one-shot)."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (agent-shell-inbox-disarm)                          ; clear any prior arm
  (unless (file-directory-p agent-shell-inbox-directory)
    (make-directory agent-shell-inbox-directory t))
  (setq agent-shell-inbox--armed-buffer (current-buffer)
        agent-shell-inbox--seen (mapcar #'file-name-nondirectory (agent-shell-inbox--images))
        agent-shell-inbox--poll-timer
        (run-with-timer agent-shell-inbox-poll-interval agent-shell-inbox-poll-interval
                        #'agent-shell-inbox--poll)
        agent-shell-inbox--timeout-timer
        (run-with-timer agent-shell-inbox-timeout nil
                        (lambda () (agent-shell-inbox-disarm) (message "agent-shell-inbox: timed out")))
        ;; Optional fast path; harmless if kqueue never fires — poll is the safety net.
        agent-shell-inbox--fn-descriptor
        (ignore-errors
          (file-notify-add-watch agent-shell-inbox-directory '(change)
                                 #'agent-shell-inbox--fn-callback)))
  (force-mode-line-update)
  (message "agent-shell-inbox: armed for %s (send a screenshot)" (buffer-name)))

(defun agent-shell-inbox-disarm ()
  "Disarm the inbox watcher (idempotent)."
  (interactive)
  (when (timerp agent-shell-inbox--poll-timer)    (cancel-timer agent-shell-inbox--poll-timer))
  (when (timerp agent-shell-inbox--timeout-timer) (cancel-timer agent-shell-inbox--timeout-timer))
  (when agent-shell-inbox--fn-descriptor
    (ignore-errors (file-notify-rm-watch agent-shell-inbox--fn-descriptor)))
  (setq agent-shell-inbox--armed-buffer nil
        agent-shell-inbox--poll-timer nil
        agent-shell-inbox--timeout-timer nil
        agent-shell-inbox--fn-descriptor nil
        agent-shell-inbox--seen nil)
  (force-mode-line-update))

;; Mode-line indicator (global-mode-string or a minor-mode lighter).
(add-to-list 'global-mode-string
             '(:eval (when agent-shell-inbox--armed-buffer
                       (propertize " 📷armed " 'face 'warning))) t)

;; Suggested keybinding.
(with-eval-after-load 'agent-shell
  (define-key agent-shell-mode-map (kbd "C-c C-i") #'agent-shell-inbox-arm))

(provide 'agent-shell-inbox)
```

Design points embedded above:

- **Buffer captured at arm time** (`current-buffer`) and passed explicitly to
  `agent-shell-insert` — this is what makes "arm from *this* buffer" correct even if the
  image lands while you're elsewhere.
- **One-shot**: `--attach` calls `disarm` *first*, so whichever of poll/`file-notify`
  fires, the other is torn down and there's no double-attach.
- **Busy-shell handling**: if the shell is mid-turn when the image lands,
  `agent-shell-insert` would `user-error`; we detect `shell-maker-busy` and leave the file
  in the inbox with a message rather than erroring inside a timer. (Refinement: could
  re-arm/defer until idle — decide in polish phase.)
- **`@`-mention split-on-space**: we keep the inbox path space-free; the timestamped
  filenames are space-free too, so no quoting needed.
- **Mode-line**: shows `📷armed` while armed; clears on attach/disarm/timeout.
- **Keybind**: `C-c C-i` is a suggestion (unbound in the base map per the README's binding
  table). Confirm it doesn't collide with your config.

---

## 9. Security considerations

- **Bot token = credential.** Anyone with it can drive your bot and (via `getUpdates`
  before you set an allowlist elsewhere) see what's sent to it. Store it in the Keychain or
  a `chmod 600` env file; never in the plist, the script, or version control. Rotate via
  BotFather `/revoke` if it leaks.
- **Chat-ID allowlist is the real access control.** The bot username is discoverable; the
  daemon must drop every update whose `message.chat.id != TELEGRAM_ALLOWED_CHAT_ID`. Without
  this, anyone who finds your bot can write files into `~/agent-inbox` and thereby inject an
  image into whatever buffer you next arm. This single check is the most important security
  line in the system.
- **Content trust.** An attached screenshot is passed to an LLM agent that may act on it
  (Claude/Gemini with tools). Treat inbound images as untrusted input just like pasted
  text; the allowlist keeps the source to you, but be aware the image content flows into an
  agent turn.
- **Inbox hygiene.** The inbox accumulates every screenshot you ever send. Consider a
  retention sweep (daemon deletes files older than N days, or Emacs deletes the attached
  file after submit). Screenshots can contain secrets (tokens on screen) — the folder is as
  sensitive as your screenshots.
- **Telegram sees your images.** By design, the screenshot transits Telegram's servers
  (it's the transport). If a screenshot is too sensitive for a third-party cloud, this
  pipeline isn't the channel for it. Worth a conscious acceptance.
- **Network egress only.** The daemon makes only outbound HTTPS to `api.telegram.org`; no
  inbound port is opened. Good posture — nothing to firewall.

---

## 10. Open questions & risks

1. **macOS `file-notify`/kqueue reliability (highest).** Addressed by making polling the
   primary mechanism (§8.1). Confirm on your actual Emacs build whether `file-notify` fires
   for directory creates; if it does, keep it as the fast path, else rely on the 1s poll.
2. **Per-agent image capability.** An agent that doesn't advertise `promptCapabilities.image`
   will silently downgrade the screenshot to a `resource`/`resource_link` block instead of an
   inline `image`. Verify once per agent you use via `M-x agent-shell-toggle-logging` →
   send an image → `M-x agent-shell-view-traffic` and confirm a `type: "image"` block. Claude
   Agent (`claude-agent-acp`) and Gemini both advertise it.
3. **Private helper `agent-shell--get-files-context`.** Using it buys the inline thumbnail
   but is an internal function that could change. Mitigation: wrap it in `ignore-errors` /
   feature-detect, and fall back to the fully-public `(concat "@" path)` form. Both attach
   identically at the ACP level.
4. **`agent-shell-insert` signature drift.** Cited signature is from current `main`.
   Pin/verify against your installed version; the fallback (§4.5 A) is the guard.
5. **Busy shell at attach time.** Handled by detecting `shell-maker-busy` and leaving the
   file for manual attach. Decide in polish whether to auto-defer until idle.
6. **Multiple images in quick succession.** MVP is strictly one-shot: only the first new
   file attaches; the rest sit in the inbox. If you often send 2–3 shots, consider a
   "stay armed until N images or timeout" mode (polish).
7. **Original PNG vs recompressed JPEG.** Screenshots of text look better sent as a Telegram
   *document* (uncompressed) than as a *photo* (JPEG-recompressed). The daemon handles both;
   the behavioral choice ("always send as file") is a habit to adopt, not code.
8. **Offset/crash semantics.** Save-before vs save-after download is a
   lose-an-image-vs-maybe-reprocess trade-off (§6.1) — pick intentionally.
9. **Time zone / filename collisions.** Timestamped names use UTC + a short random suffix to
   avoid collisions when two images land in the same second. Fine as-is.

---

## 11. Phased build order

**Phase 0 — Prove the attach primitive (30 min, no daemon).**
Manually drop a PNG at `~/agent-inbox/test.png`. In an `agent-shell` buffer, eval:
`(agent-shell-insert :text (concat "@" (expand-file-name "~/agent-inbox/test.png")) :shell-buffer (current-buffer) :no-focus t)`,
then submit and confirm via the traffic viewer that a `type:"image"` block was sent. This
de-risks the entire plan before writing anything else. If this fails, stop and re-examine
§4 against your installed version.

**Phase 1 — MVP: keybind-armed manual path, polling only.**
- Daemon: token + chat-ID allowlist, `getUpdates` long-poll, `getFile` download, atomic
  rename into `~/agent-inbox`. Run it by hand in a terminal.
- Emacs: `agent-shell-inbox-arm` (capture buffer, 1s poll, one-shot attach), `disarm`,
  timeout, `C-c C-i` binding. No `file-notify`, no mode-line yet.
- Success test: arm a buffer, send a screenshot from the phone, watch the `@path` appear;
  submit; see the image reach the agent.

**Phase 2 — Make it a background service + polish UX.**
- launchd LaunchAgent (RunAtLoad + KeepAlive), token moved to Keychain, log files.
- Mode-line `📷armed` indicator; busy-shell handling message.
- Handle `document` (uncompressed) images in the daemon.

**Phase 3 — Robustness & niceties (optional).**
- `file-notify` fast path layered over the poll (feature-detected).
- Inbox retention sweep; delete-after-attach option.
- "Stay armed for N images / until timeout" multi-image mode.
- Optional: daemon sends a Telegram reply ("received ✓") so the phone confirms delivery.

---

## 12. Sources

Primary source (code, read directly):
- `agent-shell` README — commands, image utilities, key bindings, `promptCapabilities`:
  https://github.com/xenodium/agent-shell (`README.org` on `main`)
- `agent-shell.el` source — `agent-shell-insert`, `agent-shell--insert-to-shell-buffer`,
  `agent-shell--build-content-blocks`, `agent-shell--send-command`, `agent-shell-send-*`,
  `agent-shell--get-files-context`, `agent-shell-embed-file-size-limit`:
  https://github.com/xenodium/agent-shell/blob/main/agent-shell.el
- `acp.el` README — ACP handshake, `promptCapabilities (image . t)`,
  `acp-make-session-prompt-request`: https://github.com/xenodium/acp.el
- Agent Client Protocol spec (content blocks / schema): https://agentclientprotocol.com

Telegram Bot API:
- Bot API reference (getUpdates, getFile, file download, 20 MB limit):
  https://core.telegram.org/bots/api
- getUpdates long-polling & `allowed_updates`: https://core.telegram.org/bots/api#getupdates
- Bots FAQ: https://core.telegram.org/bots/faq

Emacs:
- File Notifications (kqueue directory-watch limitations, `created`/`renamed` events):
  https://www.gnu.org/software/emacs/manual/html_node/elisp/File-Notifications.html
- `filenotify.el` source: https://github.com/emacs-mirror/emacs/blob/master/lisp/filenotify.el

macOS launchd:
- launchd LaunchAgent plist keys (RunAtLoad, KeepAlive) — Apple developer /
  `launchd.info` (`man launchd.plist`).
```
