"""Shared LED effect definitions for the VENGEANCE lights system.

One source of truth, imported by both sides of the system:
  - the device driver (windows/scripts/icue-lights.py) uses it to drive LEDs
  - the Mac engine (macos/scripts/lights/lightsctl) uses it to render previews

Both machines import their OWN repo copy, so the git repo IS the sync: same
commit on both boxes = identical colors. Pure stdlib only, so it imports
cleanly under the cuesdk venv on Windows and system python3 on the Mac.

An effect is a function fn(x, t) -> (r, g, b) with floats in 0..1, where
x = an LED's position across its device (0..1) and t = epoch seconds.
"""
import colorsys
import math
import random

# --- ember breathe -------------------------------------------------------
# Breath length and depth each drift on slow, unrelated cycles so no two
# breaths look alike. Phase is integrated frame-to-frame because the period
# keeps changing under it. This is the one the user loves — keep it intact.
BREATH_MIN_S, BREATH_MAX_S = 45, 90
DEPTH_MIN, DEPTH_MAX = 0.7, 1.0
_breath = {"phase": 0.0, "last_t": None}


def _breath_level(t, x):
    st = _breath
    if t != st["last_t"]:
        period = BREATH_MIN_S + (BREATH_MAX_S - BREATH_MIN_S) * (
            0.5 + 0.5 * math.sin(t / 137))
        dt = min(t - st["last_t"], 1.0) if st["last_t"] is not None else 0.0
        st["phase"] += 2 * math.pi * dt / period
        st["last_t"] = t
    depth = DEPTH_MIN + (DEPTH_MAX - DEPTH_MIN) * (
        0.5 + 0.5 * math.sin(t / 211 + 1))
    return depth * (0.5 - 0.5 * math.cos(st["phase"] + x * 0.6))


def _breath_raw(t, x):
    """The breath cycle WITHOUT the depth drift: hits exactly 1.0 at the peak
    of every inhale. For accents that must bottom out fully each breath."""
    _breath_level(t, x)  # tick the shared integrator for this frame
    return 0.5 - 0.5 * math.cos(_breath["phase"] + x * 0.6)


def white_ember_breathe(x, t):
    breath = _breath_level(t, x)
    return colorsys.hsv_to_rgb(0.045, breath, 1 - 0.5 * breath)


# --- fan-aware ember family ----------------------------------------------
# Effects marked fan_aware get two extra args from the Windows driver:
#   u     = the LED's fan's fraction along rig.SPREAD_ORDER (0 = bottom-front,
#           1 = side-top), constant per fan so whole fans move as units.
#           None for LEDs outside the spread path (pump); callers without a
#           rig (previews, swatches) omit it and it falls back to x.
#   group = the fan/group name from rig.FANS, or None outside the driver.
def _fan_aware(fn):
    fn.fan_aware = True
    return fn


def _heat_color(h):
    """The shared burn ramp: 0 = white, 0.5 = golden ember, 1 = deep ember.
    Same curve as white-ember breathe itself."""
    return colorsys.hsv_to_rgb(0.045, h, 1 - 0.5 * h)


@_fan_aware
def ember_gradient_breathe(x, t, u=None, group=None):
    """Every fan heats along the same ramp at the same rate; past half-ember
    each fan caps at its own temperature — the shallow end stops golden, the
    deep end burns all the way. Identical below the caps, so nothing ever
    looks stuck white."""
    u = x if u is None else u
    return _heat_color(min(_breath_level(t, x), 0.8 + 0.2 * u))


_CRIMSON_V = 0x40 / 255  # #400000 — where the RAM bottoms out at peak inhale


@_fan_aware
def blood_ram_breathe(x, t, u=None, group=None):
    """The burn. One breath heats the whole case white -> ember together on
    the same ramp; past half-ember each fan caps at its own temperature. The
    RAM is the hottest thing in the case: it rides the same ramp but never
    caps — past golden ember its hue slides amber -> red, landing on exactly
    #400000 crimson at the top of every breath (no depth drift on the RAM,
    so every inhale bottoms out fully)."""
    if group in ("ram-a", "ram-b"):
        h = _breath_raw(t, x)
        if h <= 0.5:
            return _heat_color(h)            # indistinguishable from the fans
        p = (h - 0.5) * 2                    # 0..1 over the too-hot half
        return colorsys.hsv_to_rgb(0.045 * (1 - p), 0.5 + 0.5 * p,
                                   0.75 - (0.75 - _CRIMSON_V) * p)
    u = x if u is None else u
    return _heat_color(min(_breath_level(t, x), 0.8 + 0.2 * u))


@_fan_aware
def ember_creep(x, t, u=None, group=None):
    """Fans ignite to ember one by one in physical order, hold, then the fire
    recedes the way it came. 90s per full cycle, soft ignition edges."""
    u = x if u is None else u
    p = (t % 90.0) / 90.0
    if p < 0.42:
        lit = p / 0.42
    elif p < 0.58:
        lit = 1.0
    else:
        lit = 1.0 - (p - 0.58) / 0.42
    heat = max(0.0, min(1.0, (lit * 1.12 - u) / 0.12))
    hue = 0.09 - 0.045 * heat                       # cool cream -> ember
    sat = 0.10 + 0.85 * heat
    val = 0.22 + heat * (0.38 + 0.12 * math.sin(t * 2.2 + u * 9.0))
    return colorsys.hsv_to_rgb(hue, sat, max(0.0, min(1.0, val)))


# --- named effects -------------------------------------------------------
# Insertion order is preserved; UIs list them in this order.
EFFECTS = {
    "white-ember breathe": white_ember_breathe,
    "ember gradient breathe": ember_gradient_breathe,
    "ember creep": ember_creep,
    "blood-ram breathe": blood_ram_breathe,
    "hue sweep": lambda x, t: colorsys.hsv_to_rgb((t / 600) % 1, 1, 1),
    "rainbow wave": lambda x, t: colorsys.hsv_to_rgb((x - t / 6) % 1, 1, 1),
    "purple breathe": lambda x, t: colorsys.hsv_to_rgb(
        0.78, 1, 0.08 + 0.85 * (0.5 - 0.5 * math.cos(t * math.pi / 3))),
    "ocean drift": lambda x, t: colorsys.hsv_to_rgb(
        0.5 + 0.12 * math.sin(t / 7 + x * 2), 0.85, 0.9),
    "ember": lambda x, t: colorsys.hsv_to_rgb(
        0.03 + 0.04 * x, 1, 0.55 + 0.35 * math.sin(t / 2 + x * 6)),
    "warm gruvbox": lambda x, t: colorsys.hsv_to_rgb(
        0.09 + 0.03 * math.sin(t / 9 + x * 3), 0.85, 0.9),
}

# --- presets: named pools the rotation draws from ------------------------
# A preset is a list of effect names; rotation picks randomly from the pool
# each slot. Order/content is the only thing a preset changes.
PRESETS = {
    "rotation": list(EFFECTS),                       # everything
    "ember-only": ["white-ember breathe"],
    "obsession": ["white-ember breathe", "ember gradient breathe",
                  "ember creep", "blood-ram breathe"],
    "chill": ["ocean drift", "warm gruvbox", "white-ember breathe"],
    "party": ["rainbow wave", "hue sweep", "ember"],
}


# --- 🎲 randomize --------------------------------------------------------
# One parametric effect whose knobs are rolled at random. Each roll is a
# fresh, coherent look: a base hue that drifts, a value that pulses and
# rolls across the LEDs. Pass a seed for reproducibility, or None for new.
def random_params(seed=None):
    r = random.Random(seed)
    return {
        "hue": r.random(),
        "hue_drift": r.uniform(0.0, 0.15),
        "drift_period": r.uniform(4.0, 14.0),
        "spatial": r.uniform(0.0, 3.0),
        "sat": r.uniform(0.6, 1.0),
        "v_base": r.uniform(0.30, 0.60),
        "v_amp": r.uniform(0.20, 0.50),
        "pulse": r.uniform(0.3, 2.0),
        "roll": r.uniform(0.0, 6.0),
    }


def make_parametric(p):
    def fn(x, t):
        hue = (p["hue"] + p["hue_drift"] * math.sin(
            t / p["drift_period"] + x * p["spatial"])) % 1.0
        val = p["v_base"] + p["v_amp"] * (
            0.5 - 0.5 * math.cos(t * p["pulse"] + x * p["roll"]))
        val = max(0.0, min(1.0, val))
        return colorsys.hsv_to_rgb(hue, p["sat"], val)
    return fn


# --- resolution ----------------------------------------------------------
def resolve(control, now, slot_minutes=5):
    """Given a control dict + current time, return (effect_name, fn).

    control = {
      "mode": "rotation" | "pinned" | "random",
      "preset": <preset name>,        # for rotation
      "effect": <effect name>,        # for pinned
      "params": {...},                # for random
    }
    Missing/invalid fields fall back to full rotation, never crash.
    """
    mode = (control or {}).get("mode", "rotation")
    if mode == "pinned":
        name = control.get("effect")
        if name in EFFECTS:
            return name, EFFECTS[name]
        mode = "rotation"                            # bad name -> rotate
    if mode == "random":
        params = control.get("params")
        if params:
            return "random", make_parametric(params)
        mode = "rotation"
    # rotation: random effect per slot from the preset pool, no repeats
    pool = PRESETS.get(control.get("preset", "rotation")) or list(EFFECTS)
    pool = [n for n in pool if n in EFFECTS] or list(EFFECTS)
    slot = int(now // (slot_minutes * 60))
    idx = random.Random(slot).randrange(len(pool))
    prev = random.Random(slot - 1).randrange(len(pool))
    if len(pool) > 1 and idx == prev:
        idx = (idx + 1) % len(pool)
    name = pool[idx]
    return name, EFFECTS[name]


def sample_swatch(fn, t, n=8):
    """Sample an effect across n LED positions -> list of (r,g,b) 0..255."""
    out = []
    for i in range(n):
        x = i / (n - 1) if n > 1 else 0.5
        r, g, b = fn(x, t)
        out.append([int(r * 255), int(g * 255), int(b * 255)])
    return out
