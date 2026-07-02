#!/usr/bin/env bash
# Orchestrate the EC ↔ host serial-link test
#
# SPDX-License-Identifier: MIT
#
# Owns the long-lived child processes (swtpm + EC QEMU + host QEMU),
# sets up the cleanup trap, and performs post-run verification.
#
# Run `test-sp-ec-link.sh --help` for usage. Must be executed inside the
# odp-platform-qemu-arm-virt devcontainer (requires swtpm, qemu-system-riscv32,
# qemu-system-aarch64, defmt-print, stdbuf, setsid, timeout, pkill on PATH).

set -o pipefail
# Intentionally NOT `set -e`: we use `cmd || EXIT=$?` patterns and the v1.1
# hardening cycle showed -e interferes with timeout(1) exit handling.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/swtpm.sh
source "$SCRIPT_DIR/lib/swtpm.sh"
# shellcheck source=lib/ec-qemu.sh
source "$SCRIPT_DIR/lib/ec-qemu.sh"
# shellcheck source=lib/host-qemu.sh
source "$SCRIPT_DIR/lib/host-qemu.sh"

usage() {
    cat <<'EOF'
Usage: test-sp-ec-link.sh --ec-elf PATH --bios-fv-dir DIR --build-dir DIR \
                      [--ec-timeout N] [--host-timeout N] -- <qemu-common-args...>

  --ec-elf        EC firmware ELF (riscv32)
  --bios-fv-dir   Directory containing SECURE_FLASH0.fd and QEMU_EFI.fd
  --build-dir     Build/ directory (logs and swtpm-state live here)
  --ec-timeout    Seconds for EC QEMU run (default: 30)
  --host-timeout  Seconds for host QEMU run (default: 60)
  --              Everything after this is forwarded verbatim to
                  qemu-system-aarch64 as the host common args (machine,
                  cpu, mem, smbios, etc.)

Must run inside the odp-platform-qemu-arm-virt devcontainer.

Exits 0 on PASS, non-zero on FAILURE. The first failure mode wins:
  - Setup error (swtpm socket / EC PTY discovery) -> exits 1
  - host QEMU non-zero exit -> exits with that code (verification skipped)
  - EC boot string missing  -> exits 1 (after host succeeded)
EOF
    exit "${1:-0}"
}

EC_ELF=""
BIOS_FV_DIR=""
BUILD_DIR=""
EC_TIMEOUT=30
HOST_TIMEOUT=60

require_arg() {
    # require_arg <flag-name> <value-or-empty>
    [ -n "$2" ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ec-elf)       require_arg "$1" "${2-}"; EC_ELF="$2"; shift 2 ;;
        --bios-fv-dir)  require_arg "$1" "${2-}"; BIOS_FV_DIR="$2"; shift 2 ;;
        --build-dir)    require_arg "$1" "${2-}"; BUILD_DIR="$2"; shift 2 ;;
        --ec-timeout)   require_arg "$1" "${2-}"; EC_TIMEOUT="$2"; shift 2 ;;
        --host-timeout) require_arg "$1" "${2-}"; HOST_TIMEOUT="$2"; shift 2 ;;
        -h|--help)      usage 0 ;;
        --)             shift; break ;;
        *)              echo "Unknown arg: $1" >&2; usage 1 ;;
    esac
done
# Remaining "$@" is the host QEMU common args (smbios, machine, cpu, etc.)

if [ -z "$EC_ELF" ] || [ -z "$BIOS_FV_DIR" ] || [ -z "$BUILD_DIR" ]; then
    echo "ERROR: --ec-elf, --bios-fv-dir, and --build-dir are required" >&2
    usage 1
fi

# Validate timeouts at parse time. start_ec_qemu interpolates $timeout_s into
# an inner `bash -c` string (via setsid), so non-numeric input would risk
# command injection or an empty-`timeout` syntax error inside the inner shell.
# The library trusts its caller; the orchestrator is the right place to gate.
# Reject empty, non-digit, and zero in one pattern.
case "$EC_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --ec-timeout must be a positive integer (got: $EC_TIMEOUT)" >&2; exit 1 ;;
esac
case "$HOST_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: --host-timeout must be a positive integer (got: $HOST_TIMEOUT)" >&2; exit 1 ;;
esac

# ----- tool preconditions -----
# Fail loudly here if a required tool is missing, rather than letting the
# session teardown degrade silently mid-run (e.g. a missing pkill leaks
# the EC QEMU pipeline into the devcontainer).
require_swtpm_tools || exit 1
require_ec_qemu_tools || exit 1
require_host_qemu_tools || exit 1

SWTPM_STATE="$BUILD_DIR/swtpm-state"
SWTPM_SOCK="$SWTPM_STATE/swtpm-sock"
SWTPM_LOG="$BUILD_DIR/swtpm.log"
EC_OUT_LOG="$BUILD_DIR/ec-qemu-stdout.log"
EC_ERR_LOG="$BUILD_DIR/ec-qemu-stderr.log"
EC_SERIAL_LOG="$BUILD_DIR/ec-serial-output.log"
HOST_SERIAL_LOG="$BUILD_DIR/host-serial-output.log"

EC_PID=""
SWTPM_PID=""

# shellcheck disable=SC2329  # invoked via `trap ... EXIT` below
cleanup() {
    # SC2317: invoked via `trap ... EXIT`, not statically reachable.
    # shellcheck disable=SC2317
    kill_ec_session
    # shellcheck disable=SC2317
    kill_swtpm
    # shellcheck disable=SC2317
    true
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR" "$SWTPM_STATE"
rm -f "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$HOST_SERIAL_LOG" "$SWTPM_SOCK"

# 1. swtpm
start_swtpm "$SWTPM_STATE" "$SWTPM_SOCK" "$SWTPM_LOG"
wait_for_swtpm_socket "$SWTPM_SOCK" || {
    dump_swtpm_log_on_failure "$SWTPM_LOG"
    exit 1
}

# 2. EC QEMU + PTY discovery
start_ec_qemu "$EC_ELF" "$EC_OUT_LOG" "$EC_ERR_LOG" "$EC_SERIAL_LOG" "$EC_TIMEOUT"
PTY=$(discover_ec_pty "$EC_OUT_LOG" "$EC_ERR_LOG") || exit 1
echo "EC PTY: $PTY — launching host QEMU"

# 3. host QEMU
set_host_pflash_tpm_args "$BIOS_FV_DIR" "$SWTPM_SOCK"

QEMU_ARGS=(
    "$@"
    "${HOST_PFLASH_TPM_ARGS[@]}"
    -chardev "serial,id=ec-link,path=$PTY"
    -serial "file:$HOST_SERIAL_LOG"
    -serial "chardev:ec-link"
    -drive "file=fat:rw:test-serial-vdrive,format=raw,media=disk"
    -display none
    -no-reboot
)

HOST_EXIT=0
timeout "$HOST_TIMEOUT" qemu-system-aarch64 "${QEMU_ARGS[@]}" || HOST_EXIT=$?

# 4. host failure short-circuits before verification (matches original recipe).
if [ "$HOST_EXIT" -ne 0 ]; then
    echo "host QEMU exited with code $HOST_EXIT" >&2
    exit "$HOST_EXIT"
fi

# 5. Tear down the EC pipeline BEFORE verification so that defmt-print's
# block-buffered stdout (redirected to a regular file) is fully flushed to
# $EC_SERIAL_LOG before we grep it. The original Makefile recipe got this
# for free: verification ran in a separate shell after the bash -lc subshell's
# EXIT trap had already reaped EC. Clear EC_PID so the EXIT trap below
# doesn't try to tear it down a second time.
kill_ec_session
EC_PID=""

# 6. Verification (only on host success).
PASS=true
if grep -q "Starting uart service" "$EC_SERIAL_LOG" 2>/dev/null; then
    echo "EC: boot successful (PTY serial backend)"
else
    echo "=== EC serial output ==="
    cat "$EC_SERIAL_LOG" 2>/dev/null || echo "(empty)"
    echo "=== End EC serial output ==="
    echo "EC: boot FAILED — 'Starting uart service' not found"
    PASS=false
fi

if [ -s "$HOST_SERIAL_LOG" ]; then
    echo "host: produced serial output (PTY connected)"
else
    echo "host: WARNING — no serial output captured (may be OK if boot is slow)"
fi

if "$PASS"; then
    echo "RESULT: SERIAL LINK TEST PASSED"
    exit 0
else
    echo "RESULT: SERIAL LINK TEST FAILED"
    exit 1
fi
