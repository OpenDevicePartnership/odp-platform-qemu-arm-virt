#!/usr/bin/env bash
# Run the single-QEMU e2e test suite against the secure partition.
#
# SPDX-License-Identifier: MIT
#
# Thin caller: argument parsing, tool checks, and high-level exit-code
# propagation. The swtpm launch, host QEMU invocation, serial capture,
# and result classification all live in
# scripts/lib/host-qemu.sh::run_host_efi_and_parse_results so the
# two-QEMU thermal runner (test-sp-ec-link.sh) can share the same
# parser. No EC sidecar is attached here (single-QEMU path).
#
# Run `test-sp-services.sh --help` for usage. Must be executed inside the
# odp-platform-qemu-arm-virt devcontainer (requires swtpm, qemu-system-aarch64,
# timeout on PATH).

set -o pipefail
# Intentionally NOT `set -e`: we use `cmd || EXIT=$?` patterns and rely
# on explicit exit codes for the QEMU run + log parsing. test-sp-ec-link.sh
# documents the same rationale (see v1.1 hardening cycle).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/swtpm.sh
source "$SCRIPT_DIR/lib/swtpm.sh"
# shellcheck source=lib/host-qemu.sh
source "$SCRIPT_DIR/lib/host-qemu.sh"

usage() {
    cat <<'EOF'
Usage: test-sp-services.sh BIOS_FV_DIR BUILD_DIR VDRIVE_DIR \
                           COVERAGE_PLUGIN COVERAGE_LOG HOST_TIMEOUT SERIAL_TEE \
                           -- <qemu-common-args...>

Positional args (all required, in order):
  BIOS_FV_DIR      Directory containing SECURE_FLASH0.fd and QEMU_EFI.fd
  BUILD_DIR        Build/ directory (test-output.log, swtpm state, etc. live here)
  VDRIVE_DIR       FAT drive directory exposed to UEFI shell (one .efi + startup.nsh)
  COVERAGE_PLUGIN  Path to TCG coverage plugin (.so)
  COVERAGE_LOG     Path to write QEMU coverage PC trace
  HOST_TIMEOUT     Seconds for host QEMU run (positive integer)
  SERIAL_TEE       1 = tee QEMU serial to stdout AND file; 0 = file only

After --, all remaining args are passed verbatim to qemu-system-aarch64
(typically the QEMU_COMMON_ARGS from Common.mk).

Exit codes:
  0  — banner present, "N passed, 0 failed" line present, QEMU exit 0
  1  — banner missing, [FAIL] present, timed out, or other failure
EOF
}

# ----- fixed positional contract -----
# Compact, array-preserving: 7 fixed positionals, an explicit `--`, then
# the verbatim QEMU common args. No named-option parser — the sole caller
# is e2e-tests/Makefile.
case "${1-}" in -h|--help) usage; exit 0 ;; esac

if [ "$#" -lt 8 ]; then
    echo "ERROR: expected 7 positional args + '--' before QEMU args" >&2
    usage >&2
    exit 2
fi

BIOS_FV_DIR="$1"
BUILD_DIR="$2"
VDRIVE_DIR="$3"
COVERAGE_PLUGIN="$4"
COVERAGE_LOG="$5"
HOST_TIMEOUT="$6"
SERIAL_TEE="$7"
shift 7

if [ "${1-}" != "--" ]; then
    echo "ERROR: expected '--' separator before QEMU args (got: ${1-})" >&2
    usage >&2
    exit 2
fi
shift
QEMU_COMMON_ARGS=("$@")

for var in BIOS_FV_DIR BUILD_DIR VDRIVE_DIR COVERAGE_PLUGIN COVERAGE_LOG; do
    if [ -z "${!var}" ]; then
        echo "ERROR: $var must not be empty" >&2
        usage >&2
        exit 2
    fi
done

case "$HOST_TIMEOUT" in
    ''|*[!0-9]*|0) echo "ERROR: HOST_TIMEOUT must be a positive integer (got: $HOST_TIMEOUT)" >&2; exit 2 ;;
esac
case "$SERIAL_TEE" in
    0|1) ;;
    *) echo "ERROR: SERIAL_TEE must be 0 or 1 (got: $SERIAL_TEE)" >&2; exit 2 ;;
esac

# ----- tool preconditions -----
# Fail loudly here if a required tool is missing, before any filesystem
# side effects or process launches.
require_swtpm_tools || exit 1
require_host_qemu_tools || exit 1

mkdir -p "$BUILD_DIR"

# Cleanup trap: QEMU_PID / SWTPM_PID may be set by
# run_host_efi_and_parse_results in this caller's scope; if a signal
# arrives mid-`wait`, this trap reaches them.
QEMU_PID=""
cleanup() {
    local sig=$?
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    kill_swtpm
    wait 2>/dev/null
    exit "$sig"
}
trap cleanup EXIT INT TERM

# Single-QEMU path — no EC sidecar.
EC_PTY=""

run_host_efi_and_parse_results
exit $?
