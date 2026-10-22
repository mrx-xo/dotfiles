#!/usr/bin/env python3
"""Exercise the real flash-copy UI against a temporary destination, never USB."""

import errno
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "iris-flash"


class FlashCopy(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gum"), "requires the flasher's gum dependency")
    def test_copy_runs_in_terminal_and_preserves_firmware_bytes(self):
        # Run the production copy/reconnect block with a harmless destination.
        # Redirecting gum's stderr away from the terminal prevents cp from
        # starting on macOS ("inappropriate ioctl for device").
        source = SCRIPT.read_text()
        block = source.split("  # 3. copy:", 1)[1].split("  # 4. prove it", 1)[0]
        block = block.split("\n", 1)[1]
        setup = '''
DEMO=0
UF2=$1
DRIVE=$2
step() { :; }
ok() { :; }
bad() { :; }
# Physical disconnect/reconnect is outside this copy regression test.
wait_until() { return 0; }
'''
        with tempfile.TemporaryDirectory(prefix="iris-flash-test-") as tmp:
            root = Path(tmp)
            firmware = root / "firmware.uf2"
            firmware.write_bytes(bytes(range(256)) * 512)
            destination = root / "drive"
            destination.mkdir()
            master, slave = pty.openpty()
            try:
                result = subprocess.run(
                    ["bash", "-c", setup + block, "flash-copy-test",
                     str(firmware), str(destination)],
                    stdin=slave, stdout=slave, stderr=slave,
                    env={**os.environ, "TERM": "xterm-256color"}, timeout=10,
                )
            finally:
                os.close(slave)
            output = bytearray()
            try:
                while True:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
            finally:
                os.close(master)
            self.assertEqual(result.returncode, 0, output.decode(errors="replace"))
            copied = destination / firmware.name
            self.assertTrue(copied.exists(), "flash copy never ran")
            self.assertEqual(copied.read_bytes(), firmware.read_bytes())


if __name__ == "__main__":
    unittest.main()
