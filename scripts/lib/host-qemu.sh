# shellcheck shell=bash
# Sourceable library — provides shared host QEMU args. Do not execute
# directly.
#
# SPDX-License-Identifier: MIT
#
# Required on PATH: qemu-system-aarch64, timeout
#
# Shell options (set -o pipefail, etc.) are owned by the caller.

# require_host_qemu_tools
#   Verifies the external tools this library (and the orchestrator that
#   drives it) need are on PATH. On any miss, prints the missing
#   commands to stderr and returns 1 so the orchestrator can fail loudly
#   at startup.
require_host_qemu_tools() {
    local cmd missing=()
    for cmd in qemu-system-aarch64 timeout; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ "${#missing[@]}" -eq 0 ] ||
        { echo "ERROR: missing required tools for host QEMU: ${missing[*]}" >&2; return 1; }
}

# set_host_pflash_tpm_args <bios-fv-dir> <swtpm-sock> [odp-fv-file]
#   Sets HOST_PFLASH_TPM_ARGS in the caller's scope (no `local`,
#   matching lib/swtpm.sh's start_swtpm/SWTPM_PID pattern). The array
#   contains the shared host QEMU args used by both test scripts:
#   pflash units (unit 0: SECURE_FLASH0, unit 1: QEMU_EFI, unit 2: optional odp.fd),
#   the tpm chardev + tpmdev pair, and the tpm-tis-device front-end that maps
#   the CRB MMIO region on the `virt` machine (no platform default).
set_host_pflash_tpm_args() {
    local bios_fv_dir="$1" swtpm_sock="$2" odp_fv_file="${3:-}"
    HOST_PFLASH_TPM_ARGS=(
        -drive "if=pflash,format=raw,unit=0,file=$bios_fv_dir/SECURE_FLASH0.fd"
        -drive "if=pflash,format=raw,unit=1,file=$bios_fv_dir/QEMU_EFI.fd,readonly=on"
    )
    
    if [[ -n "$odp_fv_file" && -f "$odp_fv_file" ]]; then
        HOST_PFLASH_TPM_ARGS+=(
            -drive "if=pflash,format=raw,unit=2,file=$odp_fv_file,readonly=on"
        )
    fi
    
    HOST_PFLASH_TPM_ARGS+=(
        -chardev "socket,id=chrtpm,path=$swtpm_sock"
        -tpmdev "emulator,id=tpm0,chardev=chrtpm"
        -device "tpm-tis-device,tpmdev=tpm0"
    )
}

# run_host_efi_and_parse_results
#   Canonical EFI runner shared by the single-QEMU TPM path
#   (test-sp-services.sh) and the two-QEMU thermal path
#   (test-sp-ec-link.sh). Owns swtpm lifecycle, host QEMU launch
#   (with optional EC-sidecar PTY chardev), serial capture, and the
#   grep-based result classification.
#
#   Required env vars (set by the caller before invocation):
#     BIOS_FV_DIR      Path to SECURE_FLASH0.fd / QEMU_EFI.fd
#     BUILD_DIR        Build/ root for logs, swtpm state, exit-code file
#     VDRIVE_DIR       FAT drive directory exposed to the UEFI shell
#     COVERAGE_PLUGIN  Path to QEMU TCG coverage plugin (.so)
#     COVERAGE_LOG     Output path for PC trace
#     HOST_TIMEOUT     Seconds for the host QEMU run (integer)
#     SERIAL_TEE       1 = stream serial to BOTH stdout and TEST_OUTPUT
#                          (QEMU stdio chardev with a native logfile)
#                      0 = file only
#     QEMU_COMMON_ARGS Bash array of common args (machine/cpu/mem/...)
#
#   Optional env var:
#     EC_PTY           If non-empty, the helper appends
#                      `-chardev serial,id=ec-link,path=$EC_PTY`
#                      `-serial chardev:ec-link` to host QEMU's args so
#                      the host can talk to a pre-launched EC sidecar.
#
#   Caller responsibilities (NOT done here):
#     - require_swtpm_tools / require_host_qemu_tools
#     - mkdir -p "$BUILD_DIR"
#     - any pre-cleanup of caller-owned files
#
#   Exit-code propagation (helper returns; caller propagates):
#     0  banner present, "N passed, 0 failed", QEMU exit 0
#     1  banner missing, [FAIL] present, timed out, other failure
run_host_efi_and_parse_results() {
    local SWTPM_DIR="$BUILD_DIR/tpm"
    local SWTPM_SOCK="$SWTPM_DIR/swtpm-sock"
    local SWTPM_LOG="$BUILD_DIR/swtpm.log"
    local TEST_OUTPUT="$BUILD_DIR/test-output.log"

    rm -f "$SWTPM_SOCK"

    # swtpm — start fresh under the caller's cleanup trap. SWTPM_PID is
    # set in the caller's scope by start_swtpm (no `local` in
    # lib/swtpm.sh), so the caller's existing EXIT trap can tear it
    # down on signal interruption mid-`wait`.
    start_swtpm "$SWTPM_DIR" "$SWTPM_SOCK" "$SWTPM_LOG"
    if ! wait_for_swtpm_socket "$SWTPM_SOCK"; then
        dump_swtpm_log_on_failure "$SWTPM_LOG" 2>/dev/null || true
        kill_swtpm
        return 1
    fi

    # QEMU_PID intentionally NOT local — the caller's EXIT trap reaches
    # it on signal interruption (same pattern as SWTPM_PID). Cleared at
    # end of normal-path so a follow-up call doesn't double-kill.
    QEMU_PID=""

    set_host_pflash_tpm_args "$BIOS_FV_DIR" "$SWTPM_SOCK"

    local QEMU_ARGS=(
        "${QEMU_COMMON_ARGS[@]}"
        -plugin "file=$COVERAGE_PLUGIN,outfile=$COVERAGE_LOG"
        "${HOST_PFLASH_TPM_ARGS[@]}"
        -drive "file=fat:rw:$VDRIVE_DIR,format=raw,media=disk"
        -display none
        -no-reboot
    )

    # Two-QEMU path: declare the EC-link chardev now, but defer the
    # `-serial chardev:ec-link` directive until AFTER the host's main
    # serial directive is appended below. QEMU binds -serial in
    # declaration order to serial0, serial1, ...; the host's
    # banner / [PASS]/[FAIL] / "N passed" lines must land on serial0
    # (where the UEFI shell and the test EFI write), and the EC link
    # must be serial1.
    if [ -n "${EC_PTY:-}" ]; then
        QEMU_ARGS+=(
            -chardev "serial,id=ec-link,path=$EC_PTY"
        )
    fi

    # Host serial0 backend. SERIAL_TEE=1 uses QEMU's stdio chardev with
    # a native logfile: guest serial streams to the orchestrator's
    # stdout (CI log) while QEMU itself mirrors it to TEST_OUTPUT — no
    # FIFO + tee sidecar, so $! is QEMU and `wait $QEMU_PID` surfaces
    # timeout(1)'s 124. SERIAL_TEE=0 writes TEST_OUTPUT only.
    if [ "$SERIAL_TEE" = "1" ]; then
        QEMU_ARGS+=(
            -chardev "stdio,id=hostserial,logfile=$TEST_OUTPUT,logappend=off"
            -serial "chardev:hostserial"
        )
    else
        QEMU_ARGS+=(-serial "file:$TEST_OUTPUT")
    fi
    [ -n "${EC_PTY:-}" ] && QEMU_ARGS+=(-serial "chardev:ec-link")

    timeout "$HOST_TIMEOUT" qemu-system-aarch64 "${QEMU_ARGS[@]}" &
    QEMU_PID=$!

    wait "$QEMU_PID"
    local QEMU_EXIT=$?
    QEMU_PID=""

    # Stop swtpm before result analysis (frees the socket).
    kill_swtpm

    echo "=== Test output summary ==="
    grep -E "\[(PASS|FAIL)\]" "$TEST_OUTPUT" || true
    echo ""

    if ! grep -q "EC Secure Partition E2E Tests" "$TEST_OUTPUT"; then
        echo "RESULT: TESTS NEVER RAN (banner not found in output)"
        return 1
    elif grep -q "\[FAIL\]" "$TEST_OUTPUT"; then
        echo "RESULT: SOME TESTS FAILED"
        return 1
    elif [ "$QEMU_EXIT" = "0" ] && grep -qE '^--- Results: [0-9]+ passed, 0 failed ---$' "$TEST_OUTPUT"; then
        echo "RESULT: ALL TESTS PASSED"
        return 0
    elif [ "$QEMU_EXIT" = "124" ]; then
        echo "RESULT: TIMED OUT (no test output seen)"
        return 1
    else
        echo "RESULT: NO TEST OUTPUT FOUND (exit code $QEMU_EXIT)"
        return 1
    fi
}
