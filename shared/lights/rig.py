"""Physical LED map for VENGEANCE, by name.

Derived from a live icue-identify.py session (2026-08-02): each hub group was
painted a distinct color and matched to the case by photo. Orientation:
front = glass side, back = the rear-exhaust side. The iCUE LINK hub exposes
fans as sequential 8-LED blocks, but the wiring order is scrambled vs the
physical layout — hence this hardcoded map.

Group names -> list of Corsair LED ids. Imported by both the Windows driver
(per-fan override painting) and lightsctl (name validation / UIs).
"""

_HUB_FAN_BASE = 720897  # hub channel 11; 8 LEDs per fan, ids sequential


def _fan(n):
    return list(range(_HUB_FAN_BASE + 8 * n, _HUB_FAN_BASE + 8 * n + 8))


FANS = {
    # top row (radiator), front -> back
    "top-front": _fan(5),
    "top-mid": _fan(0),
    "top-back": _fan(2),
    # bottom intake row, front -> back
    "bottom-front": _fan(1),
    "bottom-mid": _fan(4),
    "bottom-back": _fan(3),
    # rear exhaust — verified by override paint 2026-08-02: yellow showed
    # through the rear mesh (originally misread as a side fan)
    "rear": _fan(7),
    # side chamber pair, stacked vertically (verified same session: purple
    # below cyan). _fan(6) was originally misread as the rear exhaust.
    "side-top": _fan(8),
    "side-bottom": _fan(6),
    # AIO pump head — hub channel 12, 20 LEDs (unverified visually: showed no
    # color in the identify photo; may be hidden from that angle)
    "pump": list(range(786433, 786453)),
    # VENGEANCE RGB DDR5 sticks, 10 LEDs each (a = lower cx column)
    "ram-a": list(range(524289, 524299)),
    "ram-b": list(range(524299, 524309)),
}

# the physical path fan-aware effects creep along: bottom row front->back,
# up the rear, across the top back->front, then the side pair. RAM and pump
# stay off the path (they get u=None; effects fall back or special-case them).
SPREAD_ORDER = ["bottom-front", "bottom-mid", "bottom-back", "rear",
                "top-back", "top-mid", "top-front",
                "side-bottom", "side-top"]


def led_meta():
    """led id -> (u, group). u = the fan's fraction along SPREAD_ORDER
    (constant across a fan so it moves as a unit), None off the path."""
    meta = {}
    last = len(SPREAD_ORDER) - 1
    for i, name in enumerate(SPREAD_ORDER):
        for lid in FANS[name]:
            meta[lid] = (i / last, name)
    for name, ids in FANS.items():
        if name not in SPREAD_ORDER:
            for lid in ids:
                meta[lid] = (None, name)
    return meta


# convenience aliases for row-at-a-time targeting
ROWS = {
    "top": ["top-front", "top-mid", "top-back"],
    "bottom": ["bottom-front", "bottom-mid", "bottom-back"],
    "side": ["side-top", "side-bottom"],
    "ram": ["ram-a", "ram-b"],
}
