"""Blank all Corsair LEDs while this process runs; iCUE resumes on exit.

Runs nightly on VENGEANCE via scheduled task ICUELightsOff and is killed
in the morning by ICUELightsOn (`schtasks /end /tn ICUELightsOff`).
Setup: windows/scripts/setup-icue-scheduler.ps1. Requires iCUE running
in the same desktop session; venv at ~/icue-scheduler/.venv with cuesdk.
"""
import threading
import time

from cuesdk import (CueSdk, CorsairDeviceFilter, CorsairDeviceType,
                    CorsairLedColor, CorsairSessionState)

# Above iCUE's own layers (128) so black wins while we're alive
LAYER_PRIORITY = 130
# Re-assert periodically: catches device hotplug and iCUE restarts
REASSERT_SECONDS = 15

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
    sdk = CueSdk()
    sdk.connect(on_state_changed)
    while True:
        if connected.wait(timeout=60):
            try:
                sdk.set_layer_priority(LAYER_PRIORITY)
                blank_all(sdk)
            except Exception:
                pass  # iCUE mid-restart; retry next tick
        time.sleep(REASSERT_SECONDS)


if __name__ == "__main__":
    main()
