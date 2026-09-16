"""Watchdog for the resident lights engine on VENGEANCE.

Runs every couple of minutes from scheduled task ICUELightsWatchdog. The engine
(icue-lights.py) rewrites ~/icue-scheduler/status.json about every second, day
and night. A wedge inside a native cuesdk call stops that heartbeat while the
HTTP thread keeps answering /health, so nothing else notices: on 2026-09-15
the LEDs stayed frozen for 13 hours and Assist could only say "unavailable".
stop.flag does not help a wedged engine (it is checked once per loop tick).

Decision, in order: stop.flag present -> deliberate hand-back to iCUE, do
nothing. Restarted within the cooldown -> hold off, so a broken iCUE cannot
become a kill loop. No engine process -> relaunch. status.json older than
STALE_AFTER -> kill the engine chain and relaunch. Every action is one line in
~/icue-scheduler/watchdog.log; quiet runs write nothing.
"""
import os
from pathlib import Path
import subprocess
import sys
import time

STATE_DIR = Path.home() / "icue-scheduler"
STATUS_NAME = "status.json"
STOP_NAME = "stop.flag"
LOG_NAME = "watchdog.log"
SENTINEL_NAME = "watchdog.last-restart"
TASK_NAME = "ICUELights"
ENGINE_SCRIPT = "icue-lights.py"
STALE_AFTER = 60.0     # seconds without a status.json rewrite
COOLDOWN = 600.0       # seconds between restarts

# Only python.exe images whose command line names the engine script: never the
# watchdog itself, never the PowerShell that runs this query (its command line
# contains the same string, but its image is powershell.exe).
_FIND_PIDS = (
    "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'python.exe' -and "
    "$_.CommandLine -like '*" + ENGINE_SCRIPT + "*' } | "
    "Select-Object -ExpandProperty ProcessId"
)


def file_age(path, now):
    try:
        return now - os.stat(path).st_mtime
    except OSError:
        return None


def decide(state_dir, pids, now):
    state_dir = Path(state_dir)
    if (state_dir / STOP_NAME).exists():
        return "skip:stop-flag"
    since_restart = file_age(state_dir / SENTINEL_NAME, now)
    if since_restart is not None and since_restart < COOLDOWN:
        return "skip:cooldown"
    if not pids:
        return "restart:missing"
    age = file_age(state_dir / STATUS_NAME, now)
    if age is None or age > STALE_AFTER:
        return "restart:stale"
    return "ok"


def run_command(argv):
    return subprocess.run(argv, capture_output=True).returncode


def log(state_dir, now, message):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    with open(Path(state_dir) / LOG_NAME, "a", encoding="utf-8") as stream:
        stream.write(f"{stamp} {message}\n")


def restart(state_dir, pids, verdict, detail, run=run_command, now=None):
    now = time.time() if now is None else now
    state_dir = Path(state_dir)
    for pid in pids:
        run(["taskkill", "/F", "/T", "/PID", str(pid)])
    code = run(["schtasks", "/run", "/tn", TASK_NAME])
    sentinel = state_dir / SENTINEL_NAME
    sentinel.touch()
    os.utime(sentinel, (now, now))
    outcome = "relaunched" if code == 0 else f"schtasks exit {code}"
    log(state_dir, now, f"{verdict} {detail} pids={pids} {outcome}")


def parse_pids(text):
    return [int(line) for line in text.split() if line.strip().isdigit()]


def find_engine_pids():
    result = subprocess.run(["powershell", "-NoProfile", "-Command", _FIND_PIDS],
                            capture_output=True, text=True)
    return parse_pids(result.stdout)


def main():
    now = time.time()
    pids = find_engine_pids()
    verdict = decide(STATE_DIR, pids, now)
    if not verdict.startswith("restart:"):
        return 0
    age = file_age(STATE_DIR / STATUS_NAME, now)
    detail = "no engine process" if not pids else (
        "status.json missing" if age is None else f"age={age:.0f}s")
    restart(STATE_DIR, pids, verdict, detail, now=now)
    return 0


if __name__ == "__main__":
    sys.exit(main())
