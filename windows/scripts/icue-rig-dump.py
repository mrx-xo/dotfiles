"""One-shot rig dump: every Corsair device, LED id, and position, as JSON.

Run on VENGEANCE with the scheduler's venv:
  icue-scheduler/.venv/Scripts/python.exe icue-rig-dump.py
The Mac side pipes it over SSH (no file needed on the box). Read-only —
doesn't paint anything, so the resident ICUELights task is undisturbed.
"""
import json
import sys
import threading

from cuesdk import CueSdk, CorsairDeviceFilter, CorsairDeviceType, CorsairSessionState

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
out = []
for d in devs or []:
    leds, _ = sdk.get_led_positions(d.device_id)
    out.append({
        "model": d.model,
        "type": str(d.type),
        "device_id": d.device_id,
        "led_count": len(leds or []),
        "leds": [{"id": l.id, "cx": round(l.cx, 1), "cy": round(l.cy, 1)}
                 for l in leds or []],
    })
print(json.dumps(out))
# no sdk.disconnect() — SIGILLs in cuesdk 4.0.84; plain exit is the clean path
