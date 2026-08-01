"""Resident Corsair lighting driver for VENGEANCE.

Day (08:00-23:00): plays the effect chosen by ~/icue-scheduler/control.json.
By default that's the rotation — a random effect from the active preset each
5-minute slot (never the same twice in a row). control.json can instead pin
one effect or a 🎲 random parametric look; the Mac `lightsctl` writes it.
Night: all LEDs black. Runs from logon via scheduled task ICUELights;
~/icue-scheduler/stop.flag makes it hand lighting back to iCUE and exit.

Effects live in shared/lights/effects.py (imported below) so the Mac side can
render identical previews. Colors are painted at layer priority 135 (above
iCUE profiles and Wallpaper Engine). No sdk.disconnect() on exit — it SIGILLs
in cuesdk 4.0.84; dropping our layer to 0 then exiting is the clean hand-back.
Venv: ~/icue-scheduler/.venv (cuesdk). Setup: setup-icue-scheduler.ps1.
"""
import json
import sys
import threading
import time
from pathlib import Path

# shared effect definitions live at <repo>/shared/lights/effects.py
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "shared" / "lights"))
import effects  # noqa: E402

from cuesdk import (CueSdk, CorsairDeviceFilter, CorsairDeviceType,  # noqa: E402
                    CorsairLedColor, CorsairSessionState)

DAY_START_HOUR = 8
DAY_END_HOUR = 23
EFFECT_MINUTES = 5
FPS = 15
LAYER_PRIORITY = 135

STATE_DIR = Path.home() / "icue-scheduler"
STOP_FLAG = STATE_DIR / "stop.flag"
CONTROL_FILE = STATE_DIR / "control.json"
STATUS_FILE = STATE_DIR / "status.json"


def read_control():
    try:
        return json.loads(CONTROL_FILE.read_text())
    except (OSError, ValueError):
        return {"mode": "rotation", "preset": "rotation", "brightness": 1.0}


def seconds_left(control, now):
    """How long until the visible look next changes."""
    if control.get("mode", "rotation") == "rotation":
        slot = EFFECT_MINUTES * 60
        return int((now // slot + 1) * slot - now)
    return None  # pinned / random hold until the user changes them


def lights_on(control, now):
    """Should the LEDs be lit right now?  A manual override (control.force =
    'on'/'off' with a control.force_until epoch) wins until the next scheduled
    boundary; otherwise follow the 08:00-23:00 day window."""
    force = control.get("force")
    if force in ("on", "off") and now < (control.get("force_until") or 0):
        return force == "on", True          # (on?, override active)
    hour = time.localtime(now).tm_hour
    return DAY_START_HOUR <= hour < DAY_END_HOUR, False


def write_status(control, name, now, swatch, is_on, forced):
    try:
        rotation = is_on and control.get("mode", "rotation") == "rotation"
        until = control.get("force_until") if forced else None
        STATUS_FILE.write_text(json.dumps({
            "mode": control.get("mode", "rotation") if is_on else "night",
            "preset": control.get("preset", "rotation"),
            "effect": name,
            "on": is_on,
            "forced": control.get("force") if forced else None,
            "forced_until": (time.strftime("%H:%M", time.localtime(until))
                             if until else None),
            "rotation": rotation,
            "brightness": control.get("brightness", 1.0),
            "params": control.get("params"),  # for random, so UIs can animate
            "seconds_left": seconds_left(control, now) if rotation else None,
            "swatch": swatch,
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


def paint(sdk, rig, fn, t, brightness=1.0):
    for did, leds in rig:
        sdk.set_led_colors(did, [
            CorsairLedColor(id=lid, a=255, **dict(zip(
                "rgb", (int(c * brightness * 255) for c in fn(x, t)))))
            for lid, x in leds
        ])


def main():
    STOP_FLAG.unlink(missing_ok=True)
    sdk = CueSdk()
    sdk.connect(on_state_changed)
    rig = []
    last_refresh = 0.0
    status = None
    status_ts = 0.0
    while not STOP_FLAG.exists():
        if not connected.wait(timeout=60):
            continue
        now = time.time()
        try:
            if now - last_refresh > 300 or not rig:
                sdk.set_layer_priority(LAYER_PRIORITY)
                rig = build_rig(sdk)
                last_refresh = now
            control = read_control()
            is_on, forced = lights_on(control, now)
            if is_on:
                name, fn = effects.resolve(control, now, EFFECT_MINUTES)
                bright = control.get("brightness", 1.0)
                # refresh status ~1s so the swatch/countdown stay live
                if status != ("on", name) or now - status_ts > 1:
                    status = ("on", name)
                    status_ts = now
                    swatch = [[int(c * bright) for c in px]
                              for px in effects.sample_swatch(fn, now)]
                    write_status(control, name, now, swatch, True, forced)
                paint(sdk, rig, fn, now, bright)
                time.sleep(1.0 / FPS)
            else:
                # poll control often so a manual "on" lights up within ~2s
                if status != ("off", None) or now - status_ts > 1:
                    status = ("off", None)
                    status_ts = now
                    write_status(control, "black", now, [[0, 0, 0]] * 8,
                                 False, forced)
                paint(sdk, rig, lambda x, t: (0, 0, 0), now)
                time.sleep(2)
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
