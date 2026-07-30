"""Blank all Corsair LEDs while this process runs; iCUE resumes on exit.

Runs nightly on VENGEANCE via scheduled task ICUELightsOff. The morning
task ICUELightsOn creates stop.flag rather than killing the process:
iCUE 5 does NOT clear a hard-killed client's color layer (lights stay
black until iCUE restarts), and sdk.disconnect() SIGILLs in cuesdk
4.0.84 — so shutdown is "drop our layer below iCUE's, then exit".
Setup: windows/scripts/setup-icue-scheduler.ps1. Requires iCUE running
in the same desktop session; venv at ~/icue-scheduler/.venv with cuesdk.
"""
import threading
import time
from pathlib import Path

from cuesdk import (CueSdk, CorsairDeviceFilter, CorsairDeviceType,
                    CorsairLedColor, CorsairSessionState)

# Above iCUE's own layers (128) so black wins while we're alive
LAYER_PRIORITY = 130
# Re-assert periodically: catches device hotplug and iCUE restarts
REASSERT_SECONDS = 15
STOP_FLAG = Path.home() / "icue-scheduler" / "stop.flag"

connected = threading.Event()


def on_state_changed(evt):
    if evt.state == CorsairSessionState.CSS_Connected:
        connected.set()
    else:
        connected.clear()


def blank_all(sdk):
    devices, _ = sdk.get_devices(
        CorsairDeviceFilter(device_type_mask=CorsairDeviceType.CDT_All))
    for dev in devices or []:
        leds, _ = sdk.get_led_positions(dev.device_id)
        if leds:
            sdk.set_led_colors(dev.device_id, [
                CorsairLedColor(id=led.id, r=0, g=0, b=0, a=255)
                for led in leds
            ])


def main():
    STOP_FLAG.unlink(missing_ok=True)
    sdk = CueSdk()
    sdk.connect(on_state_changed)
    last_assert = 0.0
    while not STOP_FLAG.exists():
        if connected.is_set() and time.time() - last_assert >= REASSERT_SECONDS:
            try:
                sdk.set_layer_priority(LAYER_PRIORITY)
                blank_all(sdk)
                last_assert = time.time()
            except Exception:
                pass  # iCUE mid-restart; retry next tick
        time.sleep(2)
    try:
        sdk.set_layer_priority(0)  # iCUE's lighting wins again
        time.sleep(1)
    except Exception:
        pass
    STOP_FLAG.unlink(missing_ok=True)
    # no sdk.disconnect(): it crashes (SIGILL); process exit is the cleanup


if __name__ == "__main__":
    main()
