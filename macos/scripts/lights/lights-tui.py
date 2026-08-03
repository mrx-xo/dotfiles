#!/usr/bin/env python3
"""lights-tui.py — Textual dashboard skin for the VENGEANCE lights.

A thin skin over `lightsctl`: it calls the engine for state + control and
renders effect swatches LOCALLY at framerate using the shared effects module
(so the colors animate smoothly without a network round-trip per frame).
Like the gum skin, it knows nothing about SSH — swap them freely.

Setup (once):  handled by the `lights` launcher (creates .venv, installs textual)
Run:           lights           (alias)  ·  or  ./lights-tui.py

Vim navigation:
  j / k        move down / up in the focused list
  g g / G      jump to top / bottom
  l / enter    apply the highlighted effect or preset
  ctrl+d / u   page down / up
  Tab          switch between the effects and presets lists
  w            🔌 wake VENGEANCE (Wake-on-LAN, when it's off)
  r            🎲 randomize        o  rotate on       p  pin ⇄ unpin
  x            🧼 reset (clean slate: rotation, 100%, no overrides)
  [ / ]        brightness down/up  q  quit
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
from textual.binding import Binding  # noqa: E402
from textual.containers import Horizontal, Vertical  # noqa: E402
from textual.widgets import Button, Footer, Header, OptionList, Static  # noqa: E402
from textual.widgets.option_list import Option  # noqa: E402

CTL = str(Path(__file__).resolve().parent / "lightsctl")


def ctl(*args):
    return subprocess.run([CTL, *args], capture_output=True, text=True)


def ctl_json(*args):
    try:
        return json.loads(ctl(*args).stdout)
    except ValueError:
        return {}


class VimOptionList(OptionList):
    """OptionList with vim keys: j/k move, gg/G top/bottom, l/enter select."""
    BINDINGS = [
        Binding("j", "cursor_down", "down", show=False),
        Binding("k", "cursor_up", "up", show=False),
        Binding("G", "last", "bottom", show=False),
        Binding("l", "select", "select", show=False),
        Binding("space", "select", "select", show=False),
        Binding("ctrl+d", "page_down", "page down", show=False),
        Binding("ctrl+u", "page_up", "page up", show=False),
    ]

    _g_pending = False

    def on_key(self, event) -> None:
        # gg -> jump to top (two presses of g)
        if event.key == "g":
            if self._g_pending:
                self._g_pending = False
                self.action_first()
            else:
                self._g_pending = True
            event.stop()
            event.prevent_default()
        else:
            self._g_pending = False


class LightsApp(App):
    CSS = """
    Screen { layout: vertical; }
    #bright { height: 1; padding: 0 1; color: $text-muted; }
    #swatch { height: 1; padding: 0 1; }
    #bottom { height: 1fr; }
    #effects-col, #presets-col { width: 1fr; border: round $primary; }
    #status { height: auto; padding: 0 1; background: $boost; }
    #help { height: 1; color: $text-muted; padding: 0 1; }
    .hdr { text-style: bold; padding: 0 1; }
    OptionList { height: auto; }
    OptionList:focus { border-left: thick $accent; }
    Button { width: 100%; }
    """
    BINDINGS = [
        ("w", "wake", "🔌 wake"),
        ("r", "randomize", "🎲 random"),
        ("o", "rotation_on", "⟳ rotate"),
        ("p", "pin", "📌 pin/unpin"),
        ("a", "schedule", "🗓 sched"),
        ("x", "reset", "🧼 reset"),
        ("]", "bright_up", "☀+"),
        ("[", "bright_down", "☀-"),
        ("tab", "focus_next", "switch"),
        ("shift+tab", "focus_previous", "switch"),
        ("q", "quit", "quit"),
    ]

    def __init__(self):
        super().__init__()
        self.status = {}
        self.reachable = True
        self.waking = False
        self.brightness = 1.0
        self._marks = None  # (active effect, active preset) last rendered

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static("", id="bright")
        yield Static("", id="swatch")
        with Horizontal(id="bottom"):
            with Vertical(id="effects-col"):
                yield Static("effects", classes="hdr")
                yield VimOptionList(*[Option(n, id=f"e:{n}")
                                      for n in effects.EFFECTS], id="effects")
            with Vertical(id="presets-col"):
                yield Static("presets", classes="hdr")
                yield VimOptionList(*[Option(n, id=f"p:{n}")
                                      for n in effects.PRESETS], id="presets")
                yield Button("🎲 randomize (r)", id="rnd", variant="warning")
        yield Static("connecting…", id="status")
        yield Static("j/k move · gg/G top/bottom · l/⏎ apply · Tab switch · "
                     "w wake · r random · o rotate · p pin/unpin · "
                     "a schedule · x reset · "
                     "[ ] bright · q quit", id="help")
        yield Footer()

    def on_mount(self):
        self.set_interval(2.0, self.poll_state)
        self.set_interval(1 / 20, self.animate)
        self.query_one("#effects", VimOptionList).focus()
        self.poll_state()

    # --- data ----------------------------------------------------------
    @work(thread=True, exclusive=True)
    def poll_state(self):
        data = ctl_json("state", "--json")
        self.call_from_thread(self.apply_state, data)

    def mark_active(self):
        """Color the entry that's actually playing on the box: the live effect,
        and the live preset when rotation is on."""
        st = self.status
        live = self.reachable and st.get("on", True)
        eff = st.get("effect") if live and st.get("mode") != "random" else None
        pre = st.get("preset") if live and st.get("rotation") else None
        if (eff, pre) == self._marks:
            return
        self._marks = (eff, pre)
        for list_id, prefix, names, active in (
                ("effects", "e:", effects.EFFECTS, eff),
                ("presets", "p:", effects.PRESETS, pre)):
            lst = self.query_one(f"#{list_id}", VimOptionList)
            for n in names:
                prompt = (Text(f"● {n}", style="bold #50fa7b") if n == active
                          else Text(f"  {n}"))
                lst.replace_option_prompt(f"{prefix}{n}", prompt)

    def apply_state(self, data):
        self.reachable = bool(data.get("reachable"))
        self.status = data.get("lights") or {}
        self.brightness = self.status.get("brightness", 1.0)
        self.mark_active()
        self.show_brightness()
        if not self.reachable:
            msg = ("🔌 waking VENGEANCE…  (WoL sent, booting from S5)"
                   if self.waking else
                   "🔌 VENGEANCE offline  —  press [b]w[/b] to wake")
            self.query_one("#status", Static).update(msg)
            return
        self.waking = False
        st = self.status
        if not st.get("on", True):
            if st.get("forced") == "off":
                txt = (f"🌑 FORCED OFF until {st.get('forced_until')}, then "
                       "back on schedule\n   a: back on schedule now")
            else:
                txt = ("🗓 on schedule — night, LEDs black until 08:00\n"
                       "   pick an effect to light up now")
            self.query_one("#status", Static).update(txt)
            return
        # line 1: who controls power — the schedule, or a manual force
        if st.get("forced") == "on":
            power = (f"🔦 FORCED ON until {st.get('forced_until')}, then back "
                     "on schedule   ·   a: back to schedule now")
        else:
            power = "🗓 on schedule — lit 08:00–23:00, black overnight"
        # line 2: what look is playing, and whether it changes on its own
        eff = st.get("effect", "?")
        mode = st.get("mode")
        if st.get("rotation"):
            secs = st.get("seconds_left")
            nxt = "?" if secs is None else f"{secs // 60}m{secs % 60:02d}s"
            look = (f"⟳ ROTATING '{st.get('preset')}' — now: {eff}, "
                    f"next roll in {nxt}")
        elif mode == "random":
            look = "🎲 RANDOM look — holds until you change it   ·   o: rotate"
        else:
            look = (f"📌 PINNED: {eff} — holds until you change it   "
                    "·   p: unpin")
        if st.get("fans"):
            look += f"   ·   🎯 fan overrides: {', '.join(st['fans'])}"
        self.query_one("#status", Static).update(f"{power}\n{look}")

    def active_fn(self):
        if not self.reachable:
            return None
        st = self.status
        if not st.get("on", True):
            return None
        if st.get("mode") == "random" and st.get("params"):
            return effects.make_parametric(st["params"])
        return effects.EFFECTS.get(st.get("effect"))

    def animate(self):
        fn = self.active_fn()
        try:
            swatch = self.query_one("#swatch", Static)
        except Exception:  # screen tearing down; timer can outlive the widget
            return
        w = max(8, swatch.size.width - 2)
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
        swatch.update(text)

    # --- control -------------------------------------------------------
    @work(thread=True)
    def send(self, *args):
        ctl(*args)
        data = ctl_json("state", "--json")
        self.call_from_thread(self.apply_state, data)

    @work(thread=True)
    def send_seq(self, cmds):
        for c in cmds:
            ctl(*c)
        data = ctl_json("state", "--json")
        self.call_from_thread(self.apply_state, data)

    def apply_cmd(self, *cmd):
        """Change the look; if the lights are off now (night / forced-off),
        turn them on first so the change is actually visible."""
        if not self.status.get("on", True):
            self.send_seq([("on",), cmd])
        else:
            self.send(*cmd)

    @work(thread=True)
    def do_wake(self):
        ctl("wake")

    def action_wake(self):
        if self.reachable:
            self.notify("VENGEANCE is already awake")
            return
        self.waking = True
        self.query_one("#status", Static).update(
            "🔌 waking VENGEANCE…  (WoL sent, booting from S5)")
        self.do_wake()

    def on_option_list_option_selected(self, ev: OptionList.OptionSelected):
        if not self.reachable:
            self.notify("VENGEANCE is offline — press w to wake")
            return
        oid = ev.option.id or ""
        if oid.startswith("e:"):
            self.apply_cmd("set-effect", oid[2:])
        elif oid.startswith("p:"):
            self.apply_cmd("set-preset", oid[2:])

    def on_button_pressed(self, ev: Button.Pressed):
        if ev.button.id == "rnd":
            self.action_randomize()

    def action_randomize(self):
        self.apply_cmd("random")

    def action_schedule(self):
        self.send("auto")

    def action_reset(self):
        self.brightness = 1.0
        self.send("reset")

    def action_rotation_on(self):
        self.send("rotation", "on")

    def action_pin(self):
        # toggle: pinned -> unpin (rotation resumes); anything else -> pin it
        if self.status.get("mode") == "pinned":
            self.send("rotation", "on")
        else:
            self.send("rotation", "off")

    def show_brightness(self):
        self.query_one("#bright", Static).update(
            f"☀ {int(self.brightness * 100)}%")

    def action_bright_up(self):
        self.brightness = min(1.0, round(self.brightness + 0.15, 2))
        self.show_brightness()
        self.send("brightness", str(self.brightness))

    def action_bright_down(self):
        self.brightness = max(0.05, round(self.brightness - 0.15, 2))
        self.show_brightness()
        self.send("brightness", str(self.brightness))


if __name__ == "__main__":
    LightsApp().run()
