"""Paint each LED group on the LINK hub a distinct color so a photo of the
case reveals which group index is which physical fan.

Groups: LINK hub LED ids chunk by 8 per fan within a channel (id >> 16);
the 20-LED channel is the AIO pump. RAM is painted black to cut photo noise.

Runs at layer priority 140 — above the resident scheduler's 135 — for the
given number of seconds (default 300), then drops the layer and exits, and
the scheduler's effect takes back over on its next frame.

Run from the Mac:
  ssh vengeance "icue-scheduler/.venv/Scripts/python.exe - 600" \
      < windows/scripts/icue-identify.py
"""
import sys
import threading
import time

from cuesdk import (CueSdk, CorsairDeviceFilter, CorsairDeviceType,
                    CorsairLedColor, CorsairSessionState)

DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
FAN_SIZE = 8

# rainbow-ordered so neighbors stay tellable-apart even if the camera blurs hues
FAN_COLORS = [
    ("red", (255, 0, 0)),
    ("orange", (255, 90, 0)),
    ("yellow", (255, 220, 0)),
    ("green", (0, 255, 0)),
    ("cyan", (0, 255, 255)),
    ("blue", (0, 0, 255)),
    ("purple", (140, 0, 255)),
    ("magenta", (255, 0, 255)),
    ("white", (255, 255, 255)),
]
PUMP_COLORS = ((0, 255, 0), (255, 0, 255))  # alternating green/magenta

connected = threading.Event()


def on_state_changed(evt):
    if evt.state == CorsairSessionState.CSS_Connected:
        connected.set()


sdk = CueSdk()
sdk.connect(on_state_changed)
if not connected.wait(timeout=10):
    sys.exit("no iCUE session after 10s")

devs, _ = sdk.get_devices(
    CorsairDeviceFilter(device_type_mask=CorsairDeviceType.CDT_All))
plan = []  # (device_id, [CorsairLedColor ...])
fan_idx = 0
for d in devs or []:
    leds, _ = sdk.get_led_positions(d.device_id)
    if not leds:
        continue
    ids = sorted(l.id for l in leds)
    colors = []
    if d.type == CorsairDeviceType.CDT_LedController:
        by_channel = {}
        for lid in ids:
            by_channel.setdefault(lid >> 16, []).append(lid)
        for _, chan in sorted(by_channel.items()):
            if len(chan) % FAN_SIZE == 0:  # fans: 8-LED rings
                for i in range(0, len(chan), FAN_SIZE):
                    name, (r, g, b) = FAN_COLORS[fan_idx % len(FAN_COLORS)]
                    print(f"group {fan_idx}: {name}  (leds {chan[i]}..{chan[i + FAN_SIZE - 1]})")
                    colors += [CorsairLedColor(id=lid, r=r, g=g, b=b, a=255)
                               for lid in chan[i:i + FAN_SIZE]]
                    fan_idx += 1
            else:  # pump: alternating pair, unmistakable
                print(f"pump: green/magenta alternating  ({len(chan)} leds)")
                colors += [CorsairLedColor(id=lid, a=255, **dict(zip(
                    "rgb", PUMP_COLORS[i % 2]))) for i, lid in enumerate(chan)]
    else:  # RAM etc — black, keep the photo clean
        colors = [CorsairLedColor(id=lid, r=0, g=0, b=0, a=255) for lid in ids]
    plan.append((d.device_id, colors))

print(f"holding for {int(DURATION)}s — take the photo", flush=True)
sdk.set_layer_priority(140)
end = time.time() + DURATION
while time.time() < end:
    for did, colors in plan:
        sdk.set_led_colors(did, colors)
    time.sleep(0.2)

sdk.set_layer_priority(0)  # scheduler's 135 wins again
time.sleep(1)
# no sdk.disconnect() — SIGILLs in cuesdk 4.0.84; plain exit is the clean path
