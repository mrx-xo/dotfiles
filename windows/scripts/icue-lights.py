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
import colorsys
import json
import sys
import threading
import time
from pathlib import Path

# shared effect definitions live at <repo>/shared/lights/effects.py
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "shared" / "lights"))
import effects  # noqa: E402
import rig  # noqa: E402

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
        slot = effects.slot_seconds(control, EFFECT_MINUTES)
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
            "fans": control.get("fans"),      # per-fan overrides, if any
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


LED_META = rig.led_meta()  # led id -> (u, group) for fan-aware effects


def build_rig(sdk):
    devs, _ = sdk.get_devices(
        CorsairDeviceFilter(device_type_mask=CorsairDeviceType.CDT_All))
    layout = []
    for d in devs or []:
        leds, _ = sdk.get_led_positions(d.device_id)
        if not leds:
            continue
        xs = [l.cx for l in leds]
        span = (max(xs) - min(xs)) or 1.0
        layout.append((d.device_id,
                       [(l.id, (l.cx - min(xs)) / span,
                         *LED_META.get(l.id, (None, None))) for l in leds]))
    return layout


def fan_overrides(control, brightness):
    """control['fans'] = {group-name: [r, g, b] 0-255} -> {led_id: (r, g, b)}.
    Unknown group names are ignored (stale control from an older map)."""
    out = {}
    for name, col in (control.get("fans") or {}).items():
        for lid in rig.FANS.get(name, ()):
            out[lid] = tuple(int(v * brightness) for v in col)
    return out


def paint(sdk, layout, fn, t, brightness=1.0, overrides=None):
    overrides = overrides or {}
    aware = getattr(fn, "fan_aware", False)
    for did, leds in layout:
        colors = []
        for lid, x, u, group in leds:
            c = overrides.get(lid)
            if c is None:
                raw = (fn(x, t, x if u is None else u, group) if aware
                       else fn(x, t))
                k = rig.SAT_GAIN.get(group)
                if k:  # display calibration: s' = s*(1+k*s) — boost grows
                    h, s, v = colorsys.rgb_to_hsv(*raw)  # with saturation
                    raw = colorsys.hsv_to_rgb(h, min(1.0, s * (1 + k * s)), v)
                c = tuple(int(v * brightness * 255) for v in raw)
            colors.append(CorsairLedColor(id=lid, r=c[0], g=c[1], b=c[2], a=255))
        sdk.set_led_colors(did, colors)


def main():
    STOP_FLAG.unlink(missing_ok=True)
    sdk = CueSdk()
    sdk.connect(on_state_changed)
    layout = []
    last_refresh = 0.0
    status = None
    status_ts = 0.0
    while not STOP_FLAG.exists():
        if not connected.wait(timeout=60):
            continue
        now = time.time()
        try:
            if now - last_refresh > 300 or not layout:
                sdk.set_layer_priority(LAYER_PRIORITY)
                layout = build_rig(sdk)
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
                paint(sdk, layout, fn, now, bright,
                      fan_overrides(control, bright))
                time.sleep(1.0 / FPS)
            else:
                # poll control often so a manual "on" lights up within ~2s
                if status != ("off", None) or now - status_ts > 1:
                    status = ("off", None)
                    status_ts = now
                    write_status(control, "black", now, [[0, 0, 0]] * 8,
                                 False, forced)
                paint(sdk, layout, lambda x, t: (0, 0, 0), now)
                time.sleep(2)
        except Exception:
            layout = []  # iCUE restarting or device hotplug; rebuild next tick
            time.sleep(5)
    try:
        sdk.set_layer_priority(0)  # iCUE's lighting wins again
        time.sleep(1)
    except Exception:
        pass
    STOP_FLAG.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
