"""Resident Corsair lighting driver for VENGEANCE.

Day (08:00-23:00): rotates through EFFECTS, a new one every 5 minutes.
Night: all LEDs black. Runs from logon via scheduled task ICUELights;
~/icue-scheduler/stop.flag makes it hand lighting back to iCUE and exit.

Colors are painted at layer priority 135 (above iCUE profiles and
Wallpaper Engine). No sdk.disconnect() on exit — it SIGILLs in cuesdk
4.0.84; dropping our layer to 0 then exiting is the clean hand-back.
Venv: ~/icue-scheduler/.venv (cuesdk). Setup: setup-icue-scheduler.ps1.
"""
import colorsys
import json
import math
import threading
import time
from pathlib import Path

from cuesdk import (CueSdk, CorsairDeviceFilter, CorsairDeviceType,
                    CorsairLedColor, CorsairSessionState)

DAY_START_HOUR = 8
DAY_END_HOUR = 23
EFFECT_MINUTES = 5
FPS = 15
LAYER_PRIORITY = 135
STOP_FLAG = Path.home() / "icue-scheduler" / "stop.flag"

STATUS_FILE = Path.home() / "icue-scheduler" / "status.json"

# Each effect: (name, f(x, t) -> (r, g, b) floats 0-1).
# x = LED position across its device (0-1), t = epoch seconds.
EFFECTS = [
    ("hue sweep", lambda x, t: colorsys.hsv_to_rgb((t / 600) % 1, 1, 1)),
    ("rainbow wave", lambda x, t: colorsys.hsv_to_rgb((x - t / 6) % 1, 1, 1)),
    ("purple breathe", lambda x, t: colorsys.hsv_to_rgb(0.78, 1, 0.08 + 0.85 * (0.5 - 0.5 * math.cos(t * math.pi / 3)))),
    ("ocean drift", lambda x, t: colorsys.hsv_to_rgb(0.5 + 0.12 * math.sin(t / 7 + x * 2), 0.85, 0.9)),
    ("ember", lambda x, t: colorsys.hsv_to_rgb(0.03 + 0.04 * x, 1, 0.55 + 0.35 * math.sin(t / 2 + x * 6))),
    ("warm gruvbox", lambda x, t: colorsys.hsv_to_rgb(0.09 + 0.03 * math.sin(t / 9 + x * 3), 0.85, 0.9)),
]


def write_status(mode, effect, now):
    slot = EFFECT_MINUTES * 60
    try:
        STATUS_FILE.write_text(json.dumps({
            "mode": mode,
            "effect": effect,
            "since": time.strftime("%H:%M", time.localtime(now // slot * slot)),
            "next_change": time.strftime(
                "%H:%M", time.localtime((now // slot + 1) * slot))
            if mode == "day" else f"{DAY_START_HOUR:02d}:00",
            "updated": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)),
        }))
    except OSError:
        pass

connected = threading.Event()


def on_state_changed(evt):
    if evt.state == CorsairSessionState.CSS_Connected:
        connected.set()
    else:
        connected.clear()


def build_rig(sdk):
    devs, _ = sdk.get_devices(
        CorsairDeviceFilter(device_type_mask=CorsairDeviceType.CDT_All))
    rig = []
    for d in devs or []:
        leds, _ = sdk.get_led_positions(d.device_id)
        if not leds:
            continue
        xs = [l.cx for l in leds]
        span = (max(xs) - min(xs)) or 1.0
        rig.append((d.device_id,
                    [(l.id, (l.cx - min(xs)) / span) for l in leds]))
    return rig


def paint(sdk, rig, fn, t):
    for did, leds in rig:
        sdk.set_led_colors(did, [
            CorsairLedColor(id=lid, a=255,
                            **dict(zip("rgb", (int(c * 255) for c in fn(x, t)))))
            for lid, x in leds
        ])


def main():
    STOP_FLAG.unlink(missing_ok=True)
    sdk = CueSdk()
    sdk.connect(on_state_changed)
    rig = []
    last_refresh = 0.0
    status = None
    while not STOP_FLAG.exists():
        if not connected.wait(timeout=60):
            continue
        now = time.time()
        try:
            if now - last_refresh > 300 or not rig:
                sdk.set_layer_priority(LAYER_PRIORITY)
                rig = build_rig(sdk)
                last_refresh = now
            if DAY_START_HOUR <= time.localtime(now).tm_hour < DAY_END_HOUR:
                idx = int(now // (EFFECT_MINUTES * 60)) % len(EFFECTS)
                name, fn = EFFECTS[idx]
                if status != ("day", name):
                    status = ("day", name)
                    write_status(*status, now)
                paint(sdk, rig, fn, now)
                time.sleep(1.0 / FPS)
            else:
                if status != ("night", "black"):
                    status = ("night", "black")
                    write_status(*status, now)
                paint(sdk, rig, lambda x, t: (0, 0, 0), now)
                time.sleep(30)
        except Exception:
            rig = []  # iCUE restarting or device hotplug; rebuild next tick
            time.sleep(5)
    try:
        sdk.set_layer_priority(0)  # iCUE's lighting wins again
        time.sleep(1)
    except Exception:
        pass
    STOP_FLAG.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
