#!/usr/bin/env python3
"""swatch-stream.py — animated swatch frames for the Emacs lights UI.

The Emacs skin (lisp/lights.el) can't run the Python effect functions, so it
keeps one of these alive as a subprocess: it sends a control line whenever the
look changes, and reads back color frames at framerate — the same local-render
trick lights-tui.py uses, just across a pipe.

stdin   one JSON object per line, merged into the current control:
          {"effect": "ember", "params": null, "width": 40,
           "brightness": 1.0, "fps": 10}
        params non-null means random mode (effects.make_parametric).
stdout  frames: "F rrggbb rrggbb ..." (width cells), or "F off" once when
        there is nothing to draw (lights off / unknown effect).

swatch-stream.py --dump   print the effect catalog as JSON and exit:
        {"effects": [...], "groups": {...}, "presets": {...},
         "descriptions": {...}} — groups get the same 'other' bucket the
        TUI builds, so new effects never vanish from the Emacs list either.
"""
import json
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "shared" / "lights"))
import effects  # noqa: E402


def dump_catalog():
    groups = {g: [n for n in pool if n in effects.EFFECTS]
              for g, pool in effects.GROUPS.items()}
    grouped = {n for pool in groups.values() for n in pool}
    rest = [n for n in effects.EFFECTS if n not in grouped]
    if rest:
        groups["other"] = rest
    # groups/presets as ordered pairs — Emacs hash tables don't promise
    # iteration order, so the list order is part of the contract
    json.dump({"effects": list(effects.EFFECTS),
               "groups": [[g, pool] for g, pool in groups.items()],
               "presets": [[n, pool] for n, pool in effects.PRESETS.items()],
               "descriptions": effects.DESCRIPTIONS}, sys.stdout)
    print()


CTRL = {"effect": None, "params": None, "width": 40,
        "brightness": 1.0, "fps": 10}
LOCK = threading.Lock()
EOF = threading.Event()


def read_controls():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        with LOCK:
            CTRL.update(d)
    EOF.set()


def stream():
    threading.Thread(target=read_controls, daemon=True).start()
    was_off = False
    while not EOF.is_set():
        with LOCK:
            c = dict(CTRL)
        fn = (effects.make_parametric(c["params"]) if c["params"]
              else effects.EFFECTS.get(c["effect"]))
        try:
            if fn is None:
                if not was_off:
                    print("F off", flush=True)
                    was_off = True
                time.sleep(0.2)
                continue
            was_off = False
            w = max(8, int(c["width"]))
            t = time.time()
            cells = []
            for i in range(w):
                x = i / (w - 1)
                r, g, b = fn(x, t)
                cells.append("%02x%02x%02x" % tuple(
                    min(255, max(0, int(v * c["brightness"] * 255)))
                    for v in (r, g, b)))
            print("F " + " ".join(cells), flush=True)
        except BrokenPipeError:
            return
        time.sleep(1 / max(1, c["fps"]))


if __name__ == "__main__":
    if "--dump" in sys.argv:
        dump_catalog()
    else:
        stream()
