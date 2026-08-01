#!/usr/bin/env python3
"""lights-tui.py — Textual dashboard skin for the VENGEANCE lights.

A thin skin over `lightsctl`: it calls the engine for status + control and
renders effect swatches LOCALLY at framerate using the shared effects module
(so the colors animate smoothly without a network round-trip per frame).
Like the gum skin, it knows nothing about SSH — swap them freely.

Setup (once):  python3 -m pip install --user textual
Run:           ./lights-tui.py     (or: python3 lights-tui.py)

Keys: ↑/↓ + enter pick effect · r randomize · o rotation on · p pin current
      [ / ] brightness down/up · q quit
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "shared" / "lights"))
import effects  # noqa: E402

from rich.text import Text  # noqa: E402
from textual import work  # noqa: E402
from textual.app import App, ComposeResult  # noqa: E402
from textual.containers import Horizontal, Vertical  # noqa: E402
from textual.widgets import (Button, Footer, Header, OptionList,  # noqa: E402
                             Static)
from textual.widgets.option_list import Option  # noqa: E402

CTL = str(Path(__file__).resolve().parent / "lightsctl")


def ctl(*args):
    return subprocess.run([CTL, *args], capture_output=True, text=True)


def ctl_json(*args):
    try:
        return json.loads(ctl(*args).stdout)
    except ValueError:
        return {}


class LightsApp(App):
    CSS = """
    Screen { layout: horizontal; }
    #left { width: 34; border: round $primary; }
    #right { border: round $secondary; }
    #status { height: 3; content-align: left middle; padding: 0 1; }
    #swatch { height: 5; padding: 1 1; }
    #help { color: $text-muted; padding: 0 1; }
    OptionList { height: auto; }
    Button { width: 100%; margin: 0 0; }
    """
    BINDINGS = [
        ("r", "randomize", "🎲 random"),
        ("o", "rotation_on", "⟳ rotation"),
        ("p", "pin", "📌 pin"),
        ("]", "bright_up", "☀+"),
        ("[", "bright_down", "☀-"),
        ("q", "quit", "quit"),
    ]

    def __init__(self):
        super().__init__()
        self.status = {}
        self.brightness = 1.0

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Vertical(id="left"):
            yield Static("effects", classes="hdr")
            yield OptionList(*[Option(n, id=f"e:{n}")
                               for n in effects.EFFECTS], id="effects")
            yield Static("presets", classes="hdr")
            yield OptionList(*[Option(n, id=f"p:{n}")
                               for n in effects.PRESETS], id="presets")
            yield Button("🎲 randomize", id="rnd", variant="warning")
        with Vertical(id="right"):
            yield Static("connecting…", id="status")
            yield Static("", id="swatch")
            yield Static("↑/↓ + enter pick · r random · o rotation · p pin · "
                         "[ ] brightness · q quit", id="help")
        yield Footer()

    def on_mount(self):
        self.set_interval(1.5, self.poll_status)
        self.set_interval(1 / 20, self.animate)
        self.poll_status()

    # --- data ----------------------------------------------------------
    @work(thread=True, exclusive=True)
    def poll_status(self):
        st = ctl_json("status", "--json")
        self.call_from_thread(self.apply_status, st)

    def apply_status(self, st):
        self.status = st or {}
        self.brightness = self.status.get("brightness", 1.0)
        eff = self.status.get("effect", "?")
        if self.status.get("mode") == "night":
            txt = "🌙 night — LEDs black"
        elif self.status.get("rotation"):
            secs = self.status.get("seconds_left")
            nxt = "held" if secs is None else f"{secs // 60}m{secs % 60:02d}s"
            txt = (f"● {eff}   ⟳ {self.status.get('preset')}   next {nxt}"
                   f"   ☀ {int(self.brightness * 100)}%")
        else:
            txt = (f"● {eff}   📌 {self.status.get('mode')}"
                   f"   ☀ {int(self.brightness * 100)}%")
        self.query_one("#status", Static).update(txt)

    def active_fn(self):
        st = self.status
        if st.get("mode") == "random" and st.get("params"):
            return effects.make_parametric(st["params"])
        return effects.EFFECTS.get(st.get("effect"))

    def animate(self):
        fn = self.active_fn()
        w = max(8, self.query_one("#swatch", Static).size.width - 2)
        t = time.time()
        text = Text()
        if fn is None:
            text.append(" " * w)
        else:
            for i in range(w):
                x = i / (w - 1)
                r, g, b = fn(x, t)
                r, g, b = (int(c * self.brightness * 255) for c in (r, g, b))
                text.append("█", style=f"rgb({r},{g},{b})")
        self.query_one("#swatch", Static).update(text)

    # --- control -------------------------------------------------------
    @work(thread=True)
    def send(self, *args):
        ctl(*args)
        st = ctl_json("status", "--json")
        self.call_from_thread(self.apply_status, st)

    def on_option_list_option_selected(self, ev: OptionList.OptionSelected):
        oid = ev.option.id or ""
        if oid.startswith("e:"):
            self.send("set-effect", oid[2:])
        elif oid.startswith("p:"):
            self.send("set-preset", oid[2:])

    def on_button_pressed(self, ev: Button.Pressed):
        if ev.button.id == "rnd":
            self.action_randomize()

    def action_randomize(self):
        self.send("random")

    def action_rotation_on(self):
        self.send("rotation", "on")

    def action_pin(self):
        self.send("rotation", "off")

    def action_bright_up(self):
        self.brightness = min(1.0, round(self.brightness + 0.15, 2))
        self.send("brightness", str(self.brightness))

    def action_bright_down(self):
        self.brightness = max(0.05, round(self.brightness - 0.15, 2))
        self.send("brightness", str(self.brightness))


if __name__ == "__main__":
    LightsApp().run()
