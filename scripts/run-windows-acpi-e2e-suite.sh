#!/usr/bin/env bash
# Run the existing Windows ACPI service qualifications sequentially.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

die() { printf '[windows-acpi-e2e-suite] ERROR: %s\n' "$*" >&2; exit 1; }

read_base_image() {
    local record="$1" base LC_ALL=C
    [ -f "$record" ] && [ ! -L "$record" ] \
        && [ "$(realpath -e -- "$record")" = "$record" ] || return 1
    base="$(grep '^base=' "$record")" || return 1
    # Multiple records leave an embedded newline; paths cannot contain controls.
    [[ "$base" != *[[:cntrl:]]* ]] || return 1
    case "$base" in
        "base=$host_root/"*.vhdx)
            base="$repo_root/${base#"base=$host_root/"}" ;;
        *) return 1 ;;
    esac
    [ -f "$base" ] && [ ! -L "$base" ] \
        && [ "$(realpath -e -- "$base")" = "$base" ] || return 1
    printf '%s\n' "$base"
}

[ "$#" -eq 0 ] || die "this suite takes no arguments; use make variables"
[ "${IN_DEVCONTAINER:-0}" = 1 ] \
    || die "run through 'make windows-acpi-e2e-all' from the repository root"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
host_root="${WINDOWS_ACPI_E2E_HOST_ROOT:-$repo_root}"
cache="$(realpath -s -m -- "${WINDOWS_ACPI_E2E_CACHE_DIR:-$repo_root/.e2e}")"
case "$cache" in
    "$repo_root"|"$repo_root"/*) ;;
    *) die "cache must be inside the repository" ;;
esac
for directory in "$cache" "$cache/runs" "$cache/evidence"; do
    [ ! -L "$directory" ] && [ "$(realpath -m -- "$directory")" = "$directory" ] \
        || die "unsafe cache path: $directory"
done
mkdir -p "$cache/runs" "$cache/evidence"

suite_id="suite-$(date -u +%s)-$$-$RANDOM"
suite_dir="$cache/evidence/$suite_id"
mkdir "$suite_dir" || die "cannot reserve suite evidence: $suite_dir"
summary="$suite_dir/summary.tsv"
{
    printf 'commit=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
    git -C "$repo_root" status --short
} > "$suite_dir/source.txt"
if [ -n "${WINDOWS_ACPI_E2E_BASE_IMAGE:-}" ]; then
    printf 'base-image=%s\n' "$WINDOWS_ACPI_E2E_BASE_IMAGE"
else
    printf 'repository=%s\nrelease=%s\n' \
        "${WINDOWS_ACPI_E2E_REPO:-OpenDevicePartnership/odp-platform-qemu-arm-virt}" \
        "${WINDOWS_ACPI_E2E_RELEASE:-latest}"
fi > "$suite_dir/image-input.txt"
printf 'service\tstatus\texit_code\tevidence\n' > "$summary"

failed=0
pinned_base=
pin_error=
for service in thermal ucsi battery; do
    while :; do
        run_id="${suite_id#suite-}-${service:0:1}-$RANDOM"
        run_dir="$cache/runs/$run_id"
        evidence="$cache/evidence/$run_id"
        [ -e "$run_dir" ] || [ -L "$run_dir" ] \
            || [ -e "$evidence" ] || [ -L "$evidence" ] || break
    done
    host_log="$suite_dir/$service-host.log"
    if [ -n "$pin_error" ]; then
        printf '[windows-acpi-e2e-suite] ERROR: %s\n' "$pin_error" > "$host_log"
        status=BLOCKED
        exit_code=1
    elif WINDOWS_ACPI_E2E_SERVICE="$service" \
        WINDOWS_ACPI_E2E_RUN_ID="$run_id" \
        WINDOWS_ACPI_E2E_CACHE_DIR="$cache" \
        WINDOWS_ACPI_E2E_BASE_IMAGE="${pinned_base:-${WINDOWS_ACPI_E2E_BASE_IMAGE:-}}" \
        "$repo_root/scripts/run-windows-acpi-e2e.sh" > "$host_log" 2>&1; then
        status=PASS
        exit_code=0
    else
        exit_code=$?
        status=BLOCKED
        if [ -f "$run_dir/result.txt" ] || [ -f "$run_dir/qemu-status.txt" ] \
            || [ -f "$evidence/result.txt" ] || [ -f "$evidence/qemu-status.txt" ]; then
            status=FAIL
        fi
    fi
    if [ -z "${WINDOWS_ACPI_E2E_BASE_IMAGE:-}" ] && [ -z "$pin_error" ]; then
        record="$run_dir/base-image.txt"
        if [ ! -e "$record" ] && [ ! -L "$record" ]; then
            record="$evidence/base-image.txt"
        fi
        if [ -e "$record" ] || [ -L "$record" ]; then
            if base="$(read_base_image "$record")" \
                && { [ -z "$pinned_base" ] || [ "$base" = "$pinned_base" ]; }; then
                if [ -z "$pinned_base" ]; then
                    pinned_base="$base"
                    if ! {
                        printf 'pinned-service=%s\npinned-base=%s\n' "$service" "$pinned_base" \
                            && cat "$record"
                    } >> "$suite_dir/image-input.txt"; then
                        pin_error="cannot retain suite base image evidence"
                    fi
                fi
            else
                pin_error="invalid or inconsistent base image record: $record"
            fi
        elif [ "$status" != BLOCKED ]; then
            pin_error="missing base image record after $service $status"
        fi
        if [ -n "$pin_error" ]; then
            printf '[windows-acpi-e2e-suite] ERROR: %s\n' "$pin_error" \
                | tee -a "$host_log" >&2
            failed=1
        fi
    fi
    # Preflight may exit before the runner creates its evidence directory.
    if [ ! -L "$evidence" ] && mkdir -p "$evidence"; then
        cp "$host_log" "$evidence/host.log" \
            || printf 'Cannot copy host log to %s\n' "$evidence" >&2
    else
        printf 'Cannot retain per-service evidence at %s\n' "$evidence" >&2
    fi
    [ "$status" = PASS ] || failed=1
    printf '%s\t%s\t%s\t%s\n' "$service" "$status" "$exit_code" \
        "${evidence#"$repo_root"/}" >> "$summary"
done

cat "$summary"
printf 'Matrix: %s/%s\n' "$host_root" "${summary#"$repo_root"/}"
exit "$failed"
