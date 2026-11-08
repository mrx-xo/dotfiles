#!/usr/bin/env python3
"""Request a native app after iPad authentication; never unlock the device."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def run_command(args, timeout):
    process = None
    cancelled = False
    previous_handler = signal.getsignal(signal.SIGTERM)

    def defer_cancel(_signum, _frame):
        nonlocal cancelled
        cancelled = True

    # Popen can receive SIGTERM after creating the child but before returning
    # its handle. Defer raising until cleanup has ownership of that handle.
    signal.signal(signal.SIGTERM, defer_cancel)
    try:
        process = subprocess.Popen(
            ["/usr/bin/xcrun", "devicectl", *args],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        signal.signal(signal.SIGTERM, previous_handler)
        if cancelled:
            raise SystemExit(130)
        output, _ = process.communicate(timeout=timeout)
        if process.returncode:
            raise RuntimeError(output.strip() or "Device command failed")
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
        # Hammerspoon may cancel this helper when returning to Sidecar. Do not
        # leave a child devicectl process behind that could launch the app later.
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process is not None and process.stdout is not None:
            process.stdout.close()


def open_app(device, bundle, *, run=run_command, sleep=time.sleep,
             clock=time.monotonic, wait=90):
    deadline = clock() + wait
    with tempfile.TemporaryDirectory(prefix="sidecar-app-") as directory:
        result = Path(directory) / "lock.json"

        def locked(timeout):
            result.unlink(missing_ok=True)
            run(["device", "info", "lockState", "--device", device,
                 "--timeout", str(int(timeout)), "--json-output", str(result)], timeout)
            state = json.loads(result.read_text()).get("result", {}).get("passcodeRequired")
            if type(state) is not bool:
                raise RuntimeError("Cannot determine whether the iPad needs unlocking")
            return state

        # devicectl accepts a minimum timeout of five seconds. Stop before the
        # deadline rather than handing it an invalid final polling timeout.
        while (remaining := deadline - clock()) >= 5:
            if not locked(min(15, remaining)):
                remaining = deadline - clock()
                if remaining < 5:
                    break
                launch_error = None
                try:
                    run(["device", "process", "launch", "--device", device,
                         "--timeout", str(int(min(15, remaining))), bundle], min(15, remaining))
                except RuntimeError as error:
                    launch_error = error
                remaining = deadline - clock()
                if remaining < 5:
                    if launch_error:
                        raise launch_error
                    break
                if not locked(min(15, remaining)):
                    if launch_error:
                        raise launch_error
                    return
            sleep(min(2, max(0, deadline - clock())))
    raise RuntimeError("Timed out waiting for iPad unlock; unlock it and request AIDOS again")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--bundle", required=True)
    args = parser.parse_args()

    def cancelled(_signum, _frame):
        raise SystemExit(130)

    signal.signal(signal.SIGTERM, cancelled)
    try:
        open_app(args.device, args.bundle)
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, str(error) + "\n")
    print("native app launch requested")


if __name__ == "__main__":
    main()
