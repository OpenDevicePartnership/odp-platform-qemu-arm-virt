#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Five source handshakes; writes GPIO2 only, never the wake wire."""

import json
import os
from contextlib import ExitStack
from pathlib import Path
import re
import selectors
import signal
import socket
import subprocess
import sys
import time


def qmp_ack(path, sequence):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(path))
        with connection.makefile("rwb", buffering=0) as stream:
            if "QMP" not in json.loads(stream.readline()):
                raise ValueError("missing QMP greeting")
            for command in [
                {"execute": "qmp_capabilities"},
                {"execute": "input-send-event", "arguments": {"events": [
                    {"type": "key", "data": {
                        "down": down, "key": {"type": "qcode", "data": str(sequence)},
                    }} for down in [True, False]
                ]}},
            ]:
                stream.write(json.dumps(command).encode() + b"\n")
                while True:
                    response = json.loads(stream.readline())
                    if "error" in response:
                        raise ValueError(f"source acknowledgment QMP error: {response['error']}")
                    if "return" in response:
                        break
                    if "event" not in response:
                        raise ValueError(f"unexpected QMP response: {response}")


class LogRecords:
    def __init__(self):
        self.buffer = b""
        self.offset = 0

    def feed(self, chunk):
        self.buffer += chunk
        while b"\n" in self.buffer:
            raw, self.buffer = self.buffer.split(b"\n", 1)
            offset = self.offset
            self.offset += len(raw) + 1
            yield offset, raw.decode(errors="replace").rstrip("\r")


class SourceSequence:
    def __init__(self, seed, send_level, acknowledge, ec_position):
        other = "dc" if seed == "ac" else "ac"
        self.sources = [seed, other, seed, other, seed]
        self.send_level = send_level
        self.acknowledge = acknowledge
        self.ec_position = ec_position
        self.sequence = 0
        self.waiting = None
        self.applied = None
        self.applied_after = 0
        self.done = False

    def line(self, origin, offset, line):
        if line.startswith("TA_SOURCE") and origin != "host":
            raise ValueError("UEFI source marker arrived from the EC log")
        if line.startswith("TimeAlarm power input: "):
            if origin != "ec":
                raise ValueError("EC source application arrived from the host log")
            source = {"AcPower": "ac", "DcPower": "dc"}.get(line.removeprefix("TimeAlarm power input: "))
            if source is None:
                raise ValueError(f"invalid EC source record: {line}")
            if self.sequence == 0 and source != self.sources[0]:
                raise ValueError("EC startup source disagrees with the explicit model seed")
            if self.sequence:
                if (self.sequence >= len(self.sources) or self.waiting != "applied"
                        or source != self.sources[self.sequence]):
                    raise ValueError(f"unsolicited EC source application: {line}")
                if offset < self.applied_after:
                    raise ValueError("EC source record predates the GPIO2 request")
            self.applied = source
        elif line.startswith("TA_SOURCE "):
            if self.sequence >= len(self.sources) or self.waiting is not None:
                raise ValueError(f"duplicate/unexpected source request: {line}")
            expected = f"TA_SOURCE {self.sequence} {self.sources[self.sequence]}"
            if line != expected:
                raise ValueError(f"source request {line!r}, expected {expected!r}")
            self.waiting = "applied"
            if self.sequence:
                self.applied = None
                self.applied_after = self.ec_position()
                self.send_level(bytes([int(self.sources[self.sequence] == "ac")]))
        elif line.startswith("TA_SOURCE_ACK "):
            if self.sequence >= len(self.sources) or self.waiting != "ack":
                raise ValueError(f"unsolicited source acknowledgment: {line}")
            expected = f"TA_SOURCE_ACK {self.sequence} {self.sources[self.sequence]}"
            if line != expected:
                raise ValueError(f"source acknowledgment {line!r}, expected {expected!r}")
            self.sequence += 1
            self.waiting = None
        elif line == "TA_SOURCE_DONE":
            if self.done or self.sequence != len(self.sources) or self.waiting is not None:
                raise ValueError("source-switch tests completed without all five handshakes")
            self.done = True
        elif line.startswith("TA_SOURCE"):
            raise ValueError(f"malformed source marker: {line}")

        if self.waiting == "applied" and self.applied == self.sources[self.sequence]:
            self.acknowledge(self.sequence)
            self.waiting = "ack"


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise TimeoutError("source-control child did not terminate cleanly")


def run(seed, sockets, directory, timeout, command):
    # The directory is private and fresh; never consume an earlier run's markers.
    host_log = directory / "test-output.log"
    ec_log = directory / "ec-serial-output.log"
    if host_log.exists() or ec_log.exists():
        raise ValueError("source controller requires fresh host and EC logs")
    host_log.touch(exist_ok=False)
    ec_log.touch(exist_ok=False)
    end = time.monotonic() + timeout
    with socket.socket(socket.AF_UNIX) as server, selectors.DefaultSelector() as events:
        server.bind(str(sockets / "power"))
        server.listen(1)
        events.register(server, selectors.EVENT_READ, "connect")
        with (directory / "source-controller.log").open("w") as transcript:
            with subprocess.Popen(command) as child:
                child_fd = None
                try:
                    child_fd = os.pidfd_open(child.pid)
                    events.register(child_fd, selectors.EVENT_READ, "exit")
                    # Never merge raw UART and defmt bytes before framing each file.
                    with (directory / "source-tail.log").open("w") as tail_log, ExitStack() as followers:
                        records = {}
                        tails = {}
                        for origin, path in [("host", host_log), ("ec", ec_log)]:
                            tail = followers.enter_context(subprocess.Popen(
                                ["tail", "-n", "+1", "-F", f"--pid={child.pid}", str(path)],
                                stdout=subprocess.PIPE, stderr=tail_log,
                            ))
                            followers.callback(stop, tail)
                            events.register(tail.stdout, selectors.EVENT_READ, origin)
                            records[origin] = LogRecords()
                            tails[origin] = tail
                        state = None
                        open_logs = set(records)
                        while open_logs:
                            remaining = end - time.monotonic()
                            if remaining <= 0:
                                raise TimeoutError("source controller exceeded the host run deadline")
                            ready = events.select(remaining)
                            ready.sort(key=lambda event: event[0].data != "connect")
                            for key, _ in ready:
                                origin = key.data
                                if origin == "connect":
                                    peer, _ = server.accept()
                                    followers.enter_context(peer)
                                    peer.settimeout(3)
                                    events.unregister(server)
                                    state = SourceSequence(
                                        seed, peer.sendall,
                                        lambda seq: qmp_ack(sockets / "control", seq),
                                        lambda: ec_log.stat().st_size,
                                    )
                                elif origin == "exit":
                                    child.poll()
                                    events.unregister(child_fd)
                                else:
                                    chunk = os.read(key.fileobj.fileno(), 65536)
                                    if not chunk:
                                        events.unregister(key.fileobj)
                                        open_logs.remove(origin)
                                        if tails[origin].wait() != 0:
                                            raise ValueError(f"{origin} log follower failed; see source-tail.log")
                                        if records[origin].buffer.startswith(
                                            (b"TA_SOURCE", b"TimeAlarm power input:")
                                        ):
                                            raise ValueError(f"truncated {origin} control record")
                                        continue
                                    for offset, line in records[origin].feed(chunk):
                                        if line.startswith(("TA_SOURCE", "TimeAlarm power input: ")):
                                            transcript.write(f"{origin}:{offset} {line}\n")
                                            transcript.flush()
                                            if state is None:
                                                raise ValueError("source marker arrived before EC GPIO2 connected")
                                            state.line(origin, offset, line)
                        if child.poll() is None:
                            raise ValueError("source log followers closed before the host runner exited")
                        status = child.wait()
                        if status != 0:
                            return status
                        if state is None or not state.done:
                            raise ValueError("host passed without completing source-switch handshakes")
                        print("SOURCE CONTROL: all five applied/acknowledged stages completed")
                        return 0
                finally:
                    if child_fd is not None:
                        os.close(child_fd)
                    stop(child)


def main():
    if len(sys.argv) < 7 or sys.argv[5] != "--":
        raise ValueError("usage: retention-power-input.py ac|dc SOCKET_DIR RUN_DIR TIMEOUT -- COMMAND...")
    seed, sockets, directory, timeout = sys.argv[1:5]
    if seed not in ("ac", "dc") or not re.fullmatch(r"[1-9][0-9]*", timeout):
        raise ValueError("source must be ac or dc and timeout must be a positive integer")
    return run(seed, Path(sockets), Path(directory), int(timeout), sys.argv[6:])


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, _: sys.exit(128 + signum))
    try:
        sys.exit(main())
    except (OSError, ValueError, TimeoutError) as error:
        print(f"ERROR: source controller: {error}", file=sys.stderr)
        sys.exit(1)
