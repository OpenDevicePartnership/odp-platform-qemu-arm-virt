# shellcheck shell=bash
# Sourceable library — provides start_ec_qemu and discover_ec_pty (do not execute directly).
#
# SPDX-License-Identifier: MIT
#
# Required on PATH: qemu-system-riscv32, defmt-print, stdbuf, tee, setsid,
# timeout, ps, tail
#
# Functions intentionally assign EC_PID in the *caller's* shell scope
# (no `local`) so the orchestrator's cleanup trap can reach the EC's
# session/process group via `kill -- -$EC_PID`.
#
# Shell options (set -o pipefail, etc.) are owned by the caller; this
# library does not modify them.

# require_ec_qemu_tools
#   Verifies the external tools this library needs are on PATH.
require_ec_qemu_tools() {
    local cmd missing=()
    for cmd in qemu-system-riscv32 defmt-print stdbuf tee setsid timeout ps tail; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ "${#missing[@]}" -eq 0 ] ||
        { echo "ERROR: missing required tools for EC QEMU: ${missing[*]}" >&2; return 1; }
}

# start_ec_qemu <ec-elf> <stdout-log> <stderr-log> <serial-log> <timeout-secs>
#   Launches the EC QEMU (riscv32) inside its own session/process group via
#   `setsid` and sets EC_PID in the caller's shell to the session leader's
#   PID. The pipeline routes:
#     qemu stderr -> <stderr-log>
#     qemu stdout | stdbuf tee <stdout-log> | defmt-print -> <serial-log>
#
#   The EC `dev-qemu` platform runs on the custom `ec` machine (RISC-V
#   Embedded Controller), which exposes the I2C-target and GPIO lines as
#   UNIX-domain sockets plus a PTY for UART0 — mirroring the EC's own
#   launcher `mod/ec/platform/dev-qemu/qemu-ec.sh` (the single source of
#   truth for how dev-qemu is run). `qemu-system-riscv32` must therefore
#   be the `ec`-capable build from `odp-qemu-builder` (the devcontainer
#   provides it); the stock upstream binary only has the `virt` machine.
#   The I2C/GPIO sockets are non-blocking servers (wait=off) — the
#   MCTP-over-serial relay the e2e exercises rides UART0 (the PTY), so
#   nothing needs to connect to them for the thermal round-trip.
start_ec_qemu() {
    local elf="$1" out_log="$2" err_log="$3" serial_log="$4" timeout_s="$5"
    local i2c_sock="${EC_I2C_SOCK:-/tmp/qemu-ec-i2c.sock}"
    local gpio_sock="${EC_GPIO_SOCK:-/tmp/qemu-ec-gpio.sock}"
    # Stale sockets from a previous run would make `server=on` fail to bind.
    rm -f "$i2c_sock" "$gpio_sock"
    # Log files are pre-cleared by the orchestrator (`rm -f`); shell redirection
    # below creates them fresh. No truncation needed here.
    setsid bash -c "timeout $timeout_s qemu-system-riscv32 \
        -machine ec \
        -bios none \
        -kernel \"$elf\" \
        -semihosting \
        -display none \
        -serial pty \
        -monitor none \
        -no-reboot \
        -chardev socket,id=ec-i2c-target,path=\"$i2c_sock\",server=on,wait=off \
        -chardev socket,id=ec-gpio0,path=\"$gpio_sock\",server=on,wait=off \
        2> \"$err_log\" \
        | stdbuf -oL tee \"$out_log\" \
        | stdbuf -oL defmt-print -e \"$elf\"" \
        >"$serial_log" 2>&1 &
    # SC2034: EC_PID is intentionally assigned in the caller's scope so the
    # orchestrator's cleanup trap can reach the process group; not unused.
    # shellcheck disable=SC2034
    EC_PID=$!
}

# discover_ec_pty <stdout-log> <stderr-log> [tenths-of-second-timeout=100]
#   Polls QEMU's log files for the `/dev/pts/N` PTY path it printed when
#   `-serial pty` allocated one. On success: prints the PTY path to stdout
#   and returns 0. On timeout: dumps both log files to stderr and returns 1.
discover_ec_pty() {
    local out_log="$1" err_log="$2" timeout="${3:-100}" i pty=""
    for ((i = 0; i < timeout; i++)); do
        # `-h` suppresses the `filename:` prefix grep emits when given multiple
        # files; without it the result includes "ec-qemu-stdout.log:/dev/pts/N".
        pty=$(grep -ahoE '/dev/pts/[0-9]+' "$out_log" "$err_log" 2>/dev/null \
            | head -1) || true
        if [ -n "$pty" ]; then
            echo "$pty"
            return 0
        fi
        sleep 0.1
    done
    {
        echo "ERROR: EC PTY path not reported within $((timeout / 10))s"
        echo "--- EC QEMU stdout ---"
        cat "$out_log" 2>/dev/null || echo "(empty)"
        echo "--- EC QEMU stderr ---"
        cat "$err_log" 2>/dev/null || echo "(empty)"
        echo "--- End EC QEMU logs ---"
    } >&2
    return 1
}

# kill_ec_session
#   Tears down the EC session (no-op if EC_PID is unset).
#
#   EC_PID is the session leader created by `setsid`. Select every PID in
#   that exact session so pipeline process groups are cleaned without any
#   process-name matching.
kill_ec_session() {
    local pid pids=()
    [[ "$EC_PID" =~ ^[0-9]+$ ]] || return 0
    mapfile -t pids < <(ps -o pid= --sid "$EC_PID")
    for pid in "${pids[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    timeout 10 tail --pid="$EC_PID" -f /dev/null >/dev/null 2>&1 || true
    mapfile -t pids < <(ps -o pid= --sid "$EC_PID")
    for pid in "${pids[@]}"; do
        kill -KILL "$pid" 2>/dev/null || true
    done
    wait "$EC_PID" 2>/dev/null
}
