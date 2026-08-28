#!/usr/bin/env bash
# Behavioral tests for the shared single-QEMU result parser.
#
# SPDX-License-Identifier: MIT
#
# Drives scripts/lib/host-qemu.sh::classify_test_results with representative
# serial logs to guard its acceptance contract: a service pinned to an
# expected count (e.g. TPM=23) must report exactly "N passed, 0 failed",
# while the relay path (no expected count) accepts any all-green count.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/host-qemu.sh
source "$(cd "$SCRIPT_DIR/../lib" && pwd)/host-qemu.sh"

WORK_DIR="$SCRIPT_DIR/.parse-work"
rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

BANNER="=== EC Secure Partition E2E Tests ==="
FAILURES=0
CASE=0

# log <file> <body-line>: banner + a [PASS] line + the caller's results line.
log() { printf '%s\n[PASS] some_check\n%s\n' "$BANNER" "$2" >"$1"; }

# expect <desc> <want-rc> <logfile> <qemu-exit> <expected-pass>
expect() {
    local desc="$1" want="$2"
    classify_test_results "$3" "$4" "$5" >/dev/null 2>&1
    local got=$?
    CASE=$((CASE + 1))
    if [ "$got" = "$want" ]; then
        echo "ok $CASE - $desc"
    else
        echo "not ok $CASE - $desc (want rc=$want, got rc=$got)"
        FAILURES=$((FAILURES + 1))
    fi
}

log "$WORK_DIR/ok.log"   "--- Results: 23 passed, 0 failed ---"
log "$WORK_DIR/wrong.log" "--- Results: 22 passed, 0 failed ---"
log "$WORK_DIR/fail.log" "[FAIL] broken"$'\n'"--- Results: 23 passed, 1 failed ---"
log "$WORK_DIR/relay.log" "--- Results: 3 passed, 0 failed ---"
printf '%s\n' "--- Results: 23 passed, 0 failed ---" >"$WORK_DIR/nobanner.log"

expect "exact expected count accepted"          0 "$WORK_DIR/ok.log"       0 23
expect "wrong all-green count rejected"         1 "$WORK_DIR/wrong.log"    0 23
expect "[FAIL] rejected"                        1 "$WORK_DIR/fail.log"     0 23
expect "nonzero QEMU exit rejected"             1 "$WORK_DIR/ok.log"       1 23
expect "missing results banner rejected"        1 "$WORK_DIR/nobanner.log" 0 23
expect "relay (empty expected) accepts count"   0 "$WORK_DIR/relay.log"    0 ''

echo "1..$CASE"
if [ "$FAILURES" -ne 0 ]; then
    echo "FAILED: $FAILURES case(s)" >&2
    exit 1
fi
echo "All $CASE parser cases passed"
