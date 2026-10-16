#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Source-only handshakes over local sockets and logs; no VM or EC bypass."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "retention-power-input.py"
SPEC = importlib.util.spec_from_file_location("power_input", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

CHILD = r"""
import json, pathlib, socket, sys
seed, sockets, directory = sys.argv[1:]
sockets, directory = pathlib.Path(sockets), pathlib.Path(directory)
host = directory / "test-output.log"
ec = directory / "ec-serial-output.log"
def line(path, text):
    with path.open("a") as out:
        out.write(text + "\n")
with socket.socket(socket.AF_UNIX) as power, socket.socket(socket.AF_UNIX) as qmp:
    power.settimeout(5)
    power.connect(str(sockets / "power"))
    qmp.settimeout(5)
    qmp.bind(str(sockets / "control"))
    qmp.listen(1)
    other = "dc" if seed == "ac" else "ac"
    line(ec, "TimeAlarm power input: " + ("AcPower" if seed == "ac" else "DcPower"))
    for seq, source in enumerate([seed, other, seed, other, seed]):
        line(host, f"TA_SOURCE {seq} {source}")
        if seq:
            assert power.recv(1) == bytes([int(source == "ac")])
            line(ec, "TimeAlarm power input: " + ("AcPower" if source == "ac" else "DcPower"))
        connection, _ = qmp.accept()
        with connection, connection.makefile("rwb", buffering=0) as stream:
            stream.write(b'{"QMP":{}}\n')
            assert json.loads(stream.readline()) == {"execute": "qmp_capabilities"}
            stream.write(b'{"return":{}}\n')
            command = json.loads(stream.readline())
            assert command["execute"] == "input-send-event"
            events = command["arguments"]["events"]
            assert [e["data"]["down"] for e in events] == [True, False]
            assert all(e["data"]["key"] == {"type": "qcode", "data": str(seq)} for e in events)
            stream.write(b'{"return":{}}\n')
        if seq == 0:
            power.setblocking(False)
            try:
                assert not power.recv(1), "controller overwrote the startup seed"
            except BlockingIOError:
                pass
            power.settimeout(5)
        line(host, f"TA_SOURCE_ACK {seq} {source}")
    line(host, "TA_SOURCE_DONE")
    line(host, "--- Results: 6 passed, 0 failed ---")
"""


class SourceTests(unittest.TestCase):
    def state(self, seed="ac"):
        levels, acknowledgments = [], []
        return MODULE.SourceSequence(seed, levels.append, acknowledgments.append, lambda: 0), levels, acknowledgments

    def test_initial_seed_is_never_written_and_application_is_required(self):
        state, levels, acks = self.state()
        state.line("host", 0, "TA_SOURCE 0 ac")
        self.assertEqual(acks, [])
        state.line("ec", 0, "TimeAlarm power input: AcPower")
        self.assertEqual(acks, [0])
        self.assertEqual(levels, [])
        state.line("host", 0, "TA_SOURCE_ACK 0 ac")
        state.line("host", 0, "TA_SOURCE 1 dc")
        self.assertEqual(levels, [b"\0"])
        self.assertEqual(acks, [0])
        state.line("ec", 0, "TimeAlarm power input: DcPower")
        self.assertEqual(acks, [0, 1])

    def test_replayed_wrong_or_missing_stages_cannot_complete(self):
        for marker in ["TA_SOURCE 1 dc", "TA_SOURCE 0 dc", "TA_SOURCE_DONE", "TA_SOURCE_ACK 0 ac"]:
            state, _, _ = self.state()
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                state.line("host", 0, marker)
        state, _, _ = self.state()
        state.line("host", 0, "TA_SOURCE 0 ac")
        with self.assertRaises(ValueError):
            state.line("host", 0, "TA_SOURCE 0 ac")
        with self.assertRaises(ValueError):
            state.line("ec", 0, "TimeAlarm power input: DcPower")

    def test_interleaved_partial_files_preserve_records_and_causality(self):
        logs = {origin: MODULE.LogRecords() for origin in ["host", "ec"]}
        positions = {"host": 0, "ec": 0}
        effects = []
        state = MODULE.SourceSequence(
            "ac", lambda level: effects.append(("write", level)),
            lambda seq: effects.append(("ack", seq)), lambda: positions["ec"],
        )

        def feed(origin, chunk):
            positions[origin] += len(chunk)
            for offset, line in logs[origin].feed(chunk):
                state.line(origin, offset, line)

        feed("host", b"TA_SOU")
        feed("ec", b"TimeAlarm power input: AcPower\n")
        feed("host", b"RCE 0 ac\r")
        feed("ec", b"TimeAlarm wake requested: false\n")
        self.assertEqual(effects, [])
        feed("host", b"\nTA_SOURCE_ACK 0 ac\n")
        self.assertEqual(effects, [("ack", 0)])

        for byte in b"TA_SOURCE 1 dc":
            feed("host", bytes([byte]))
            feed("ec", b"EC diagnostic\n")
            self.assertEqual(effects, [("ack", 0)])
        feed("host", b"\n")
        self.assertEqual(effects, [("ack", 0), ("write", b"\0")])
        for byte in b"TimeAlarm power input: DcPower":
            feed("ec", bytes([byte]))
            feed("host", b"UEFI diagnostic\n")
            self.assertEqual(effects, [("ack", 0), ("write", b"\0")])
        feed("ec", b"\n")
        self.assertEqual(effects, [("ack", 0), ("write", b"\0"), ("ack", 1)])
        feed("host", b"TA_SOURCE_ACK 1 dc\n")
        self.assertEqual(state.sequence, 2)
        self.assertTrue(all(not log.buffer for log in logs.values()))

    def test_record_origins_cannot_impersonate_each_other(self):
        for origin, line in [
            ("ec", "TA_SOURCE 0 ac"),
            ("host", "TimeAlarm power input: AcPower"),
        ]:
            state, _, _ = self.state()
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                state.line(origin, 0, line)

    def test_partial_ec_record_started_before_request_cannot_acknowledge_it(self):
        ec = MODULE.LogRecords()
        acknowledgments, levels = [], []
        state = MODULE.SourceSequence(
            "ac", levels.append, acknowledgments.append,
            lambda: ec.offset + len(ec.buffer),
        )
        for offset, line in ec.feed(b"TimeAlarm power input: AcPower\n"):
            state.line("ec", offset, line)
        state.line("host", 0, "TA_SOURCE 0 ac")
        state.line("host", 0, "TA_SOURCE_ACK 0 ac")
        self.assertEqual(list(ec.feed(b"TimeAlarm power input: DcPower")), [])
        state.line("host", 0, "TA_SOURCE 1 dc")
        with self.assertRaisesRegex(ValueError, "predates"):
            for offset, line in ec.feed(b"\n"):
                state.line("ec", offset, line)
        self.assertEqual(levels, [b"\0"])
        self.assertEqual(acknowledgments, [0])

    def test_qmp_error_is_not_an_application_acknowledgment(self):
        import socket
        with tempfile.TemporaryDirectory(prefix="power-input-test-") as temp:
            path = Path(temp) / "control"
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path))
                server.listen(1)
                server.settimeout(5)
                def reject():
                    connection, _ = server.accept()
                    with connection, connection.makefile("rwb", buffering=0) as stream:
                        stream.write(b'{"QMP":{}}\n')
                        stream.readline()
                        stream.write(b'{"error":{"desc":"capabilities rejected"}}\n')
                worker = threading.Thread(target=reject)
                worker.start()
                try:
                    with self.assertRaisesRegex(ValueError, "QMP error"):
                        MODULE.qmp_ack(path, 0)
                finally:
                    worker.join(timeout=5)
                self.assertFalse(worker.is_alive())

    def test_live_handshakes_for_both_startup_sources(self):
        for seed in ["ac", "dc"]:
            with self.subTest(seed=seed), tempfile.TemporaryDirectory(prefix="power-input-test-") as temp:
                root = Path(temp)
                sockets, directory = root / "sockets", root / "logs"
                sockets.mkdir()
                directory.mkdir()
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), seed, str(sockets), str(directory), "30", "--",
                     sys.executable, "-c", CHILD, seed, str(sockets), str(directory)],
                    capture_output=True, text=True, timeout=40, check=False,
                )
                diagnostics = result.stdout + result.stderr
                for log in ["source-tail.log", "source-controller.log"]:
                    diagnostics += (directory / log).read_text()
                self.assertEqual(result.returncode, 0, diagnostics)
                self.assertIn("all five applied/acknowledged stages completed", result.stdout)
                transcript = (directory / "source-controller.log").read_text()
                self.assertEqual(transcript.count("TA_SOURCE_ACK "), 5)
                self.assertNotIn("wake", " ".join(p.name for p in sockets.iterdir()))

    def test_fresh_logs_and_completed_handshakes_are_mandatory(self):
        with tempfile.TemporaryDirectory(prefix="power-input-test-") as temp:
            root = Path(temp)
            (root / "test-output.log").touch()
            with self.assertRaises(ValueError):
                MODULE.run("ac", root, root, 5, ["true"])
        with tempfile.TemporaryDirectory(prefix="power-input-test-") as temp:
            root = Path(temp)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "ac", str(root), str(root), "5", "--", "true"],
                capture_output=True, text=True, timeout=10, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without completing source-switch handshakes", result.stderr)

    def test_controller_failure_terminates_its_owned_runner(self):
        child = r"""
import pathlib, signal, socket, sys
root = pathlib.Path(sys.argv[1])
def terminate(*_):
    (root / "terminated").touch()
    sys.exit(0)
signal.signal(signal.SIGTERM, terminate)
with socket.socket(socket.AF_UNIX) as power:
    power.connect(str(root / "power"))
    (root / "test-output.log").write_text("TA_SOURCE_DONE\n")
    signal.pause()
"""
        with tempfile.TemporaryDirectory(prefix="power-input-test-") as temp:
            root = Path(temp)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "ac", str(root), str(root), "10", "--",
                 sys.executable, "-c", child, str(root)],
                capture_output=True, text=True, timeout=20, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without all five handshakes", result.stderr)
            self.assertTrue((root / "terminated").exists())


if __name__ == "__main__":
    unittest.main()
