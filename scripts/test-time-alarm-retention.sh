#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

if [ "$#" -lt 11 ] || [ "${10}" != -- ]; then
    echo "Usage: $0 ac|dc connected|disconnected|power-input EC_ELF BIOS_FV_DIR BUILD_ROOT EFI COVERAGE_PLUGIN TIMEOUT SERIAL_TEE -- QEMU_ARGS..." >&2
    exit 2
fi
source_mode=$1 wire=$2 ec_elf=$3 bios=$4 root=$5 efi=$6 plugin=$7 timeout_s=$8 tee_serial=$9
shift 10
case "$source_mode" in ac|dc) ;; *) echo "ERROR: select ac or dc" >&2; exit 2 ;; esac
case "$wire" in connected|disconnected|power-input) ;; *) echo "ERROR: select connected, disconnected, or power-input" >&2; exit 2 ;; esac
for file in "$ec_elf" "$efi" "$plugin" "$bios/SECURE_FLASH0.fd" "$bios/QEMU_EFI.fd"; do
    [ -f "$file" ] || { echo "ERROR: missing artifact: $file" >&2; exit 1; }
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$root"
run=$(mktemp -d "$root/$source_mode-$wire.XXXXXX")
sockets=$(mktemp -d /tmp/odp-retention.XXXXXX)
cleanup() {
    local status=$?
    if ! rm -f "$sockets/i2c" "$sockets/hid" "$sockets/wake" "$sockets/power" "$sockets/control" || ! rmdir "$sockets"; then
        echo "ERROR: failed to clean retention sockets: $sockets" >&2
        if [ "$status" -eq 0 ]; then status=1; fi
    fi
    exit "$status"
}
trap cleanup EXIT
export EC_I2C_SOCK="$sockets/i2c" EC_GPIO_SOCK="$sockets/hid" EC_WAKE_SOCK="$sockets/wake"
mkdir "$run/vdrive"
cp "$efi" "$run/vdrive/time_alarm_retention.efi"
app_args="$source_mode $wire"
[ "$wire" != power-input ] || app_args="power-input $source_mode"
sed "s/^    %a$/    %a $app_args/" "$script_dir/../e2e-tests/startup.nsh" > "$run/vdrive/startup.nsh"

gpio_args=(
    -chardev "socket,id=ec-i2c-controller,path=$EC_I2C_SOCK,server=off,reconnect-ms=1000"
    -chardev "socket,id=gpio0,path=$EC_GPIO_SOCK,server=off,reconnect-ms=1000"
)
if [ "$wire" != disconnected ]; then
    gpio_args+=(-chardev "socket,id=gpio1,path=$EC_WAKE_SOCK,server=off,reconnect-ms=1000")
    export EXPECTED_PASS=6
else
    export EXPECTED_PASS=4
fi
controller=()
if [ "$wire" = power-input ]; then
    export EC_POWER_SOCK="$sockets/power" EC_POWER_SOURCE="$source_mode"
    gpio_args+=(-qmp "unix:$sockets/control,server=on,wait=off")
    controller=(python3 "$script_dir/retention-power-input.py" "$source_mode" "$sockets" "$run" "$timeout_s" --)
fi
echo "Retention fixture: source=$source_mode wire=$wire EC=$ec_elf logs=$run"
"${controller[@]}" "$script_dir/test-sp-ec-link.sh" \
    "$ec_elf" "$bios" "$run" "$run/vdrive" "$plugin" "$run/coverage.log" \
    "$timeout_s" "$timeout_s" "$tee_serial" -- "$@" "${gpio_args[@]}"
