#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Runner failure and compatibility boundaries; no real QEMU processes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RetentionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="retention-runner-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        (self.root / "e2e-tests").mkdir()
        shutil.copy(ROOT / "e2e-tests/startup.nsh", self.root / "e2e-tests")
        shutil.copy(ROOT / "scripts/test-time-alarm-retention.sh", self.scripts)
        self.record = self.root / "record.json"
        self.env = dict(os.environ, RECORD=str(self.record))
        self.env.pop("EC_QEMU", None)
        self.env.pop("EC_POWER_SOCK", None)
        self.env.pop("EC_POWER_SOURCE", None)
        self.elf = self.root / "fixture ' quoted.elf"
        self.elf.touch()
        self.bios = self.root / "bios"
        self.bios.mkdir()
        for name in ["SECURE_FLASH0.fd", "QEMU_EFI.fd"]:
            (self.bios / name).touch()
        self.executable(self.scripts / "test-sp-ec-link.sh", """#!/usr/bin/env python3
import os, pathlib, sys
pathlib.Path(os.environ['RECORD']).write_text(os.environ['EC_WAKE_SOCK'])
for key in ['EC_I2C_SOCK', 'EC_GPIO_SOCK', 'EC_WAKE_SOCK']:
    pathlib.Path(os.environ[key]).touch()
sys.exit(int(os.environ.get('STUB_EXIT', '0')))
""")

    @staticmethod
    def executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def run_fixture(self, source, wire):
        return subprocess.run(
            ["bash", str(self.scripts / "test-time-alarm-retention.sh"),
             source, wire, str(self.elf), str(self.bios), str(self.root / "runs"),
             str(self.elf), str(self.elf), "180", "0", "--", "-machine", "virt"],
            env=self.env, capture_output=True, text=True, check=False,
        )

    def test_invalid_selection_never_launches(self):
        for source, wire in [("", "connected"), ("battery", "connected"), ("ac", "invalid")]:
            with self.subTest(source=source, wire=wire):
                self.assertEqual(self.run_fixture(source, wire).returncode, 2)
                self.assertFalse(self.record.exists())

    def test_child_failure_propagates_and_cleans_sockets(self):
        self.env["STUB_EXIT"] = "1"
        self.assertEqual(self.run_fixture("ac", "connected").returncode, 1)
        self.assertFalse(Path(self.record.read_text()).parent.exists())

    def test_explicit_ec_binary_preserves_default_gpio(self):
        tools = self.root / "tools"
        tools.mkdir()
        self.executable(tools / "qemu-system-riscv32", "#!/usr/bin/env bash\nexit 99\n")
        self.executable(tools / "defmt-print", "#!/usr/bin/env bash\ncat\n")
        qemu = self.root / "isolated ec qemu"
        self.executable(qemu, """#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['RECORD']).write_text(json.dumps(sys.argv))
""")
        self.env.update(PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        EC_QEMU=str(qemu), EC_ELF=str(self.elf),
                        EC_I2C_SOCK=str(self.root / "i2c"), EC_GPIO_SOCK=str(self.root / "hid"),
                        EC_WAKE_SOCK="", LOG_ROOT=str(self.root),
                        EC_LIBRARY=str(ROOT / "scripts/lib/ec-qemu.sh"))
        result = subprocess.run(
            ["bash", "-c", 'source "$EC_LIBRARY"; require_ec_qemu_tools || exit; '
             'start_ec_qemu "$EC_ELF" "$LOG_ROOT/out" "$LOG_ROOT/err" "$LOG_ROOT/serial" 5; wait "$EC_PID"'],
            env=self.env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.record.read_text())
        self.assertEqual(args[0], str(qemu))
        self.assertIn(str(self.elf), args)
        self.assertIn(f"socket,id=ec-gpio0,path={self.root / 'hid'},server=on,wait=off", args)
        self.assertFalse(any("id=ec-gpio1," in arg for arg in args))
        self.assertFalse(any("id=ec-gpio2," in arg for arg in args))
        for source, reset in [("ac", "4"), ("dc", "0")]:
            with self.subTest(source=source):
                self.env.update(EC_POWER_SOCK=str(self.root / "power"), EC_POWER_SOURCE=source)
                result = subprocess.run(
                    ["bash", "-c", 'source "$EC_LIBRARY"; start_ec_qemu "$EC_ELF" '
                     '"$LOG_ROOT/out" "$LOG_ROOT/err" "$LOG_ROOT/serial" 5; wait "$EC_PID"'],
                    env=self.env, capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(self.record.read_text())
                self.assertIn("odp-gpio.input-reset-mask=4", args)
                self.assertIn(f"odp-gpio.input-reset={reset}", args)
                self.assertIn(f"socket,id=ec-gpio2,path={self.root / 'power'},server=off", args)

    def test_probe_is_not_wake_acceptance(self):
        log = self.root / "probe.log"
        log.write_text("=== EC Secure Partition E2E Tests ===\n"
                       "RETENTION PROBE READY: read-only checks; not wake acceptance\n"
                       "--- Results: 3 passed, 0 failed ---\n")
        for count in [3, 4, 6]:
            with self.subTest(expected=count):
                result = subprocess.run(
                    ["bash", "-c", 'source "$1"; classify_test_results "$2" 0 "$3"',
                     "bash", str(ROOT / "scripts/lib/host-qemu.sh"), str(log), str(count)],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0 if count == 3 else 1)


if __name__ == "__main__":
    unittest.main()
