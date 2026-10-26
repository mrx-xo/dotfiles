#!/usr/bin/env python3
"""Route agent-owned windows and explicitly visit/leave their workspace.

Application names are not ownership: personal Brave stays unrestricted.
Only known browser profile directories and the named sandbox daemon qualify.
"""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

HERE = Path(__file__).resolve().parent
STATE = Path.home() / ".local/state/agent-workspace"
PROFILE = Path.home() / ".local/share/agent-browser"
PORT = int(os.environ.get("AGENT_BROWSER_PORT", "9333"))


def run(*args, check=True, timeout=15):
    return subprocess.run(list(map(str, args)), check=check, capture_output=True,
                          text=True, timeout=timeout).stdout.strip()


def yabai(*args, **kwargs):
    return run("yabai", "-m", *args, **kwargs)


def query(kind):
    return json.loads(yabai("query", "--" + kind))


def owned_process(command):
    if re.search(r"(?:^| )--(?:fg-)?daemon=sandbox(?: |$)", command):
        return True
    match = re.search(r"(?:^| )--user-data-dir=(.*?)(?= --|$)", command)
    if not match:
        return False
    profile = match.group(1).strip('"\'')
    return profile in {str(PROFILE), str(Path.home() / ".cache/chrome-devtools-mcp/chrome-profile")}


def agent_pids(profile=None):
    result = set()
    for line in run("ps", "-wwaxo", "pid=,args=").splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and owned_process(fields[1]) and (
                profile is None or re.search(r"(?:^| )--user-data-dir=" + re.escape(str(profile)) + r"(?: --|$)", fields[1])):
            result.add(int(fields[0]))
    return result


def ensure_space():
    spaces = query("spaces")
    if not any(s["label"] == "agent" for s in spaces):
        yabai("space", "--create", "last")
        yabai("space", "last", "--label", "agent")
        spaces = query("spaces")
    return next(s for s in spaces if s["label"] == "agent")


def route(window_id=None, pids=None):
    space = ensure_space()
    pids = agent_pids() if pids is None else pids
    for w in query("windows"):
        if window_id is not None and w["id"] != window_id:
            continue
        if (w["app"] in ("Brave Browser", "Emacs") and w["pid"] in pids
                and w["subrole"] == "AXStandardWindow" and w["space"] != space["index"]):
            yabai("window", str(w["id"]), "--space", "agent")


def snapshot():
    spaces, windows = query("spaces"), query("windows")
    return {"space": next((s["id"] for s in spaces if s["has-focus"]), None),
            "window": next((w["id"] for w in windows if w["has-focus"]), None),
            "visible": [s["id"] for s in spaces if s["is-visible"]]}


def restore(saved, background=False):
    spaces, windows = query("spaces"), query("windows")
    focused = next((w for w in windows if w["has-focus"]), None)
    # A deliberate switch to another personal window wins over our snapshot.
    if (background and focused and focused["id"] != saved["window"]
            and focused["pid"] not in agent_pids()):
        return
    for s in spaces:
        if s["id"] in saved["visible"] and not s["is-visible"]:
            yabai("display", str(s["display"]), "--space", str(s["index"]), check=False)
    if focused and focused["id"] == saved["window"]:
        return
    if any(w["id"] == saved["window"] for w in windows):
        yabai("window", "--focus", str(saved["window"]))
    else:
        origin = next((s for s in spaces if s["id"] == saved["space"]), None)
        if origin:
            yabai("space", "--focus", str(origin["index"]))


@contextmanager
def background_launch():
    # Serialize our launchers so two agents cannot restore each other's focus.
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "launch.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        saved = snapshot()
        try:
            yield
        finally:
            restore(saved, background=True)


def toggle(state_file=None):
    path = state_file or STATE / "return.json"
    agent = ensure_space()
    current = next((s for s in query("spaces") if s["has-focus"]), None)
    if current and current["label"] == "agent":
        if not path.exists():
            raise RuntimeError("No saved return window; visit another desktop first.")
        restore(json.loads(path.read_text()))
    else:
        # Visit on the display in use. Move before the snapshot, so the return
        # point records what the vacated display falls back to.
        if current and agent["display"] != current["display"]:
            yabai("space", "agent", "--display", str(current["display"]))
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(snapshot()))
        temporary.replace(path)
        yabai("space", "--focus", "agent")


def browser_ready():
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/version", timeout=1) as response:
            ready = bool(json.load(response).get("webSocketDebuggerUrl"))
        if ready:
            listeners = {int(pid) for pid in run("lsof", "-t", "-nP", f"-iTCP:{PORT}",
                                                "-sTCP:LISTEN", check=False).splitlines()}
            if not listeners or not listeners.issubset(agent_pids(PROFILE)):
                raise RuntimeError("DevTools port belongs to another process; refusing to use it.")
        return ready
    except (OSError, ValueError):
        return False


def open_url(url):
    if not url.startswith(("http://", "https://", "file://")):
        raise ValueError("Expected an http, https, or file URL")
    with background_launch():
        run(HERE / "agent-space-ensure")
        if not browser_ready():
            PROFILE.mkdir(parents=True, exist_ok=True)
            # -n is essential: do not send URLs or arguments to personal Brave.
            # Only the background CDP path creates its window.
            run("open", "-g", "-n", "-a", "Brave Browser", "--args",
                f"--remote-debugging-port={PORT}", f"--user-data-dir={PROFILE}",
                "--no-first-run", "--no-default-browser-check", "--no-startup-window")
            for _ in range(60):
                if browser_ready():
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError("Agent Brave did not expose DevTools; personal Brave was not used.")
        # Failure is reported, never retried through an activating URL handler.
        run(HERE / "agent-browser-newtab", url)
        for _ in range(30):
            pids = agent_pids(PROFILE)
            if any(w["app"] == "Brave Browser" and w["pid"] in pids for w in query("windows")):
                route(pids=pids)
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Agent tab opened but no agent browser window appeared.")


def sandbox_frame(show=False, test=False):
    client = os.environ.get("EMACSCLIENT", "/opt/homebrew/opt/emacs-plus@30/bin/emacsclient")
    # Do not use emacsclient -c: its server path raises the new frame.
    expression = """(progn
      (unless (and (equal (daemonp) "sandbox") (equal server-name "sandbox"))
        (error "Not the sandbox daemon"))
      (let ((frame (or (seq-find (lambda (f) (and (display-graphic-p f)
                                                  (not (frame-parent f)))) (frame-list))
                       (make-frame '((name . "SANDBOX") (no-focus-on-map . t))))))
        (modify-frame-parameters frame '((no-focus-on-map . t)))
        (make-frame-visible frame)
        %s
        (frame-parameter frame 'outer-window-id)))""" % (
            "(with-selected-frame frame (mr-x/sandbox-test-env))" if test else "")
    with background_launch():
        run(HERE / "agent-space-ensure")
        run(client, "--socket-name=sandbox", "--eval", expression)
        pid = int(run(client, "--socket-name=sandbox", "--eval", "(emacs-pid)"))
        route(pids={pid})
    if show:
        if not any(s["label"] == "agent" and s["has-focus"] for s in query("spaces")):
            toggle()
        pids = agent_pids()
        window = next((w for w in query("windows") if w["app"] == "Emacs"
                       and w["pid"] in pids and w["subrole"] == "AXStandardWindow"), None)
        if window:
            yabai("window", "--focus", str(window["id"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("toggle", "route", "open", "sandbox-frame"), nargs="?", default="toggle")
    parser.add_argument("value", nargs="?")
    parser.add_argument("--show", action="store_true")
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()
    if args.command == "toggle":
        toggle()
    elif args.command == "route":
        route(int(args.value) if args.value else None)
    elif args.command == "open":
        open_url(args.value or "")
    else:
        sandbox_frame(args.show, args.test)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"agent-workspace: {exc}", file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError) and exc.stderr:
            print(exc.stderr.strip(), file=sys.stderr)
        sys.exit(1)
