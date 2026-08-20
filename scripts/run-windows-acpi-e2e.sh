#!/usr/bin/env bash
# Build and run the Windows ACPI thermal end-to-end test.
#
# SPDX-License-Identifier: MIT

if [ -z "${ODP_WINDOWS_ACPI_E2E_SOURCE_ONLY:-}" ]; then
    set -euo pipefail
fi

ODP_E2E_PASS_LINE='PASS: Windows ACPI E2E'
ODP_E2E_MIN_BUILD=28000
ODP_E2E_ASSET_NAME='os-image.zip'
ODP_E2E_IMAGE_NAME='os-image.vhdx'
ODP_E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODP_E2E_REPO_ROOT="$(dirname "$ODP_E2E_SCRIPT_DIR")"
ODP_E2E_HOST_ROOT="${WINDOWS_ACPI_E2E_HOST_ROOT:-$ODP_E2E_REPO_ROOT}"
ODP_E2E_PAYLOAD_DIR="$ODP_E2E_REPO_ROOT/postbuild/os/windows-acpi-e2e"
ODP_E2E_SECURE_MANIFEST="$ODP_E2E_REPO_ROOT/mod/secure-services/Build/qemu-ec-sp.dts"
ODP_E2E_CACHE_DIR="${ODP_E2E_CACHE_DIR:-}"
ODP_E2E_TMPDIR="${ODP_E2E_TMPDIR:-}"
EC_PID="${EC_PID:-}"
QEMU_PID="${QEMU_PID:-}"

# shellcheck source=lib/ec-qemu.sh
source "$ODP_E2E_SCRIPT_DIR/lib/ec-qemu.sh"

odp_e2e_log() { printf '[windows-acpi-e2e] %s\n' "$*" >&2; }
odp_e2e_warn() { printf '[windows-acpi-e2e] WARN: %s\n' "$*" >&2; }
odp_e2e_error() { printf '[windows-acpi-e2e] ERROR: %s\n' "$*" >&2; }
odp_e2e_die() { printf '[windows-acpi-e2e] ERROR: %s\n' "$*" >&2; exit 1; }

odp_e2e_host_path() {
    local path="$1"
    case "$path" in
        "$ODP_E2E_REPO_ROOT")
            printf '%s\n' "$ODP_E2E_HOST_ROOT"
            ;;
        "$ODP_E2E_REPO_ROOT"/*)
            printf '%s%s\n' "$ODP_E2E_HOST_ROOT" "${path#"$ODP_E2E_REPO_ROOT"}"
            ;;
        *)
            printf '%s\n' "$path"
            ;;
    esac
}

odp_e2e_default_cache_dir() {
    printf '%s/.e2e\n' "$ODP_E2E_REPO_ROOT"
}

odp_e2e_safe_path() {
    local path="$1" root="$2" lexical_root lexical_path relative current component
    local components=()
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    lexical_root="$(realpath -s -m -- "$root")" || return 1
    [ "$(realpath -e -- "$root")" = "$lexical_root" ] || return 1
    lexical_path="$(realpath -s -m -- "$path")" || return 1
    case "$lexical_path" in
        "$lexical_root"|"$lexical_root"/*) ;;
        *) return 1 ;;
    esac
    relative="${lexical_path#"$lexical_root"}"
    relative="${relative#/}"
    current="$lexical_root"
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        [ -n "$component" ] || continue
        current="$current/$component"
        [ ! -L "$current" ] || return 1
    done
}

odp_e2e_validate_socket_path() {
    local path="$1" LC_ALL=C
    [ "${#path}" -le 107 ] || {
        odp_e2e_error \
            "UNIX socket path exceeds 107 bytes; set WINDOWS_ACPI_E2E_CACHE_DIR to a shorter in-repository path"
        return 1
    }
}

odp_e2e_resolve_base_asset() {
    local release_json="$1" asset="$2"
    jq -er --arg name "$asset" '
        select((.assets | type) == "array")
        | [.assets[] | select(type == "object" and .name == $name)]
        | select(length == 1)
        | .[0]
        | select((.id | type) == "number" and .id > 0 and .id == (.id | floor))
        | select((.digest | type) == "string"
            and (.digest | test("^sha256:[0-9A-Fa-f]{64}$")))
        | "\(.id)|\(.digest | ascii_downcase)"
    ' "$release_json"
}

odp_e2e_file_matches_digest() {
    local file="$1" digest="$2" expected
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    expected="${digest#sha256:}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ "$(sha256sum "$file" | awk '{print $1}')" = "$expected" ]
}

odp_e2e_download_asset() {
    local url="$1" digest="$2" final="$3" temporary
    odp_e2e_file_matches_digest "$final" "$digest" && return 0
    [ ! -L "$final" ] || return 1
    mkdir -p "$(dirname "$final")"
    temporary="${final}.part.$$.$RANDOM"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        curl --fail --location --silent --show-error --retry 3 \
            -H 'Accept: application/octet-stream' --output "$temporary" "$url" \
            || exit 1
        odp_e2e_file_matches_digest "$temporary" "$digest" || exit 1
        [ ! -L "$final" ] || exit 1
        mv -f -- "$temporary" "$final" || exit 1
        trap - EXIT HUP INT TERM
    )
}

odp_e2e_validate_vhdx() {
    qemu-img info --output=json "$1" 2>/dev/null | jq -e '.format == "vhdx"' >/dev/null
}

odp_e2e_extract_base() {
    local archive="$1" digest="$2" cache="$3" hex final_dir final checksum stage
    local members=() matching=()
    hex="${digest#sha256:}"
    final_dir="$cache/bases/$hex"
    final="$final_dir/$ODP_E2E_IMAGE_NAME"
    checksum="$final_dir/$ODP_E2E_IMAGE_NAME.sha256"
    if [ -f "$final" ] && [ ! -L "$final" ] && [ -f "$checksum" ] \
        && [ ! -L "$checksum" ] && odp_e2e_validate_vhdx "$final" \
        && (cd "$final_dir" && sha256sum -c "$ODP_E2E_IMAGE_NAME.sha256" \
            >/dev/null 2>&1); then
        printf '%s\n' "$final"
        return 0
    fi
    [ ! -e "$final_dir" ] && [ ! -L "$final_dir" ] || return 1
    mapfile -t members < <(unzip -Z1 "$archive")
    for member in "${members[@]}"; do
        [ "$member" = "$ODP_E2E_IMAGE_NAME" ] && matching+=("$member")
        case "$member" in /*|../*|*/../*) return 1 ;; esac
    done
    [ "${#matching[@]}" -eq 1 ] || return 1
    mkdir -p "$cache/bases"
    stage="${final_dir}.part.$$.$RANDOM"
    (
        trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
        mkdir "$stage" || exit 1
        unzip -p "$archive" "$ODP_E2E_IMAGE_NAME" > "$stage/$ODP_E2E_IMAGE_NAME" \
            || exit 1
        odp_e2e_validate_vhdx "$stage/$ODP_E2E_IMAGE_NAME" || exit 1
        (
            cd "$stage"
            sha256sum "$ODP_E2E_IMAGE_NAME" > "$ODP_E2E_IMAGE_NAME.sha256"
        ) || exit 1
        [ ! -e "$final_dir" ] && [ ! -L "$final_dir" ] || exit 1
        mv -- "$stage" "$final_dir" || exit 1
        trap - EXIT HUP INT TERM
    )
    printf '%s\n' "$final"
}

odp_e2e_validate_base_image() {
    local base="$1" digest="$2" cache="$3" hex marker temporary has_cli build
    hex="${digest#sha256:}"
    [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || return 1
    marker="$cache/validated/$hex"
    odp_e2e_safe_path "$marker" "$cache" || return 1
    if [ -f "$marker" ] && [ ! -L "$marker" ]; then
        return 0
    fi
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    has_cli="$(odp_e2e_guestfish --ro --format=vhdx -a "$base" -i \
        is-file /ectest/ec-test-cli.exe)" || return 1
    [ "$(printf '%s' "$has_cli" | tr -d '\r[:space:]')" = true ] || return 1
    build="$(
        TMPDIR="$ODP_E2E_TMPDIR" \
        LIBGUESTFS_CACHEDIR="$ODP_E2E_CACHE_DIR/libguestfs-cache" \
        LIBGUESTFS_TMPDIR="$ODP_E2E_CACHE_DIR/libguestfs-tmp" \
            virt-win-reg --format vhdx "$base" \
            'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' \
            CurrentBuildNumber
    )" || return 1
    build="$(printf '%s' "$build" | tr -d '\r[:space:]')"
    [[ "$build" =~ ^[0-9]+$ ]] || return 1
    if ((10#$build < ODP_E2E_MIN_BUILD)); then
        odp_e2e_error \
            "WinVOS base build $build is unsupported; Windows ACPI FF-A requires $ODP_E2E_MIN_BUILD or newer"
        return 1
    fi
    mkdir -p "$(dirname "$marker")"
    temporary="${marker}.part.$$.$RANDOM"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        printf 'build=%s\ncli=C:\\ectest\\ec-test-cli.exe\n' "$build" > "$temporary"
        [ ! -e "$marker" ] && [ ! -L "$marker" ] || exit 1
        mv -- "$temporary" "$marker"
        trap - EXIT HUP INT TERM
    )
}

odp_e2e_make_overlay() {
    local base="$1" overlay="$2" root relative temporary
    [ -f "$base" ] && [ ! -L "$base" ] || return 1
    root="${ODP_E2E_CACHE_DIR:-$(dirname "$(dirname "$overlay")")}"
    odp_e2e_safe_path "$overlay" "$root" || return 1
    [ ! -e "$overlay" ] && [ ! -L "$overlay" ] || return 1
    mkdir -p "$(dirname "$overlay")"
    relative="$(realpath -m --relative-to="$(dirname "$overlay")" "$base")"
    temporary="${overlay}.part.$$.$RANDOM"
    (
        trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
        cd "$(dirname "$overlay")"
        qemu-img create -q -f qcow2 -F vhdx -b "$relative" "$(basename "$temporary")"
        mv -- "$(basename "$temporary")" "$(basename "$overlay")"
        trap - EXIT HUP INT TERM
    )
}

odp_e2e_guestfish() {
    TMPDIR="$ODP_E2E_TMPDIR" \
    LIBGUESTFS_CACHEDIR="$ODP_E2E_CACHE_DIR/libguestfs-cache" \
    LIBGUESTFS_TMPDIR="$ODP_E2E_CACHE_DIR/libguestfs-tmp" \
        guestfish "$@"
}

odp_e2e_preflight_libguestfs() {
    local log="$ODP_E2E_CACHE_DIR/libguestfs-test-tool.log"
    if TMPDIR="$ODP_E2E_TMPDIR" \
        LIBGUESTFS_CACHEDIR="$ODP_E2E_CACHE_DIR/libguestfs-cache" \
        LIBGUESTFS_TMPDIR="$ODP_E2E_CACHE_DIR/libguestfs-tmp" \
            libguestfs-test-tool > "$log" 2>&1; then
        return 0
    fi
    odp_e2e_error \
        "libguestfs appliance unavailable; rebuild the devcontainer (kernel, modules, and readable /boot/vmlinuz are required); details: $(odp_e2e_host_path "$log")"
    return 1
}

odp_e2e_verify_secure_manifest() {
    local manifest="$1"
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        odp_e2e_error "generated secure partition manifest missing: $(odp_e2e_host_path "$manifest")"
        return 1
    fi
    grep -Eq \
        '^[[:space:]]*(uuid[[:space:]]*=[[:space:]]*)?<0xa76df531 0x724d3c59 0xc78fb3a4 0x73c01a17>[,;][[:space:]]*$' \
        "$manifest" || {
        odp_e2e_error "generated secure partition manifest thermal UUID word tuple mismatch: $(odp_e2e_host_path "$manifest")"
        return 1
    }
    grep -Eq '^[[:space:]]*id[[:space:]]*=[[:space:]]*<0x8002>[[:space:]]*;' \
        "$manifest" || {
        odp_e2e_error "generated secure partition manifest partition ID mismatch: $(odp_e2e_host_path "$manifest")"
        return 1
    }
    grep -Eq \
        '^[[:space:]]*messaging-method[[:space:]]*=[[:space:]]*<0x603>[[:space:]]*;' \
        "$manifest" || {
        odp_e2e_error "generated secure partition manifest direct request/response capability mismatch: $(odp_e2e_host_path "$manifest")"
        return 1
    }
}

odp_e2e_inject_run_payload() {
    local overlay="$1" acpi="$2" run_cmd="$3" test_file="$4"
    odp_e2e_guestfish -a "$overlay" -i \
        mkdir-p /odp-e2e \
        : rm-f /odp-e2e/result.txt \
        : rm-f /odp-e2e/thermal.log \
        : upload "$acpi" /Windows/System32/ACPITABL.dat \
        : upload "$run_cmd" /odp-e2e/run.cmd \
        : upload "$test_file" /odp-e2e/thermal.test
}

odp_e2e_set_startup_shell() {
    local overlay="$1" registry="$2"
    cat > "$registry" <<'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"Shell"="cmd.exe /c C:\\odp-e2e\\run.cmd"
EOF
    TMPDIR="$ODP_E2E_TMPDIR" \
    LIBGUESTFS_CACHEDIR="$ODP_E2E_CACHE_DIR/libguestfs-cache" \
    LIBGUESTFS_TMPDIR="$ODP_E2E_CACHE_DIR/libguestfs-tmp" \
        virt-win-reg --format qcow2 --merge "$overlay" < "$registry"
}

odp_e2e_build_acpi() {
    local run_dir="$1" tables output
    tables="$ODP_E2E_REPO_ROOT/mod/uefi/platform/QemuArmVirtPkg/AcpiTables"
    output="$run_dir/acpi"
    mkdir -p "$output"
    iasl -tc -p "$output/ec" -I "$tables" "$tables/ec.asl" \
        > "$run_dir/acpi-build.log" 2>&1
    cp "$output/ec.aml" "$output/ACPITABL.dat"
    printf '%s\n' "$output/ACPITABL.dat"
}

odp_e2e_extract_results() {
    local overlay="$1" run_dir="$2"
    odp_e2e_guestfish --ro -a "$overlay" -i \
        download /odp-e2e/result.txt "$run_dir/result.txt" \
        : download /odp-e2e/thermal.log "$run_dir/thermal.log"
}

odp_e2e_verify_result() {
    local result="$1" thermal="$2" ec="$3" status="$4"
    [ "$(tr -d '\r' < "$result")" = "$ODP_E2E_PASS_LINE" ] || return 1
    tr -d '\r' < "$thermal" | grep -qxF \
        '[test] SUMMARY C:\odp-e2e\thermal.test: 1 passed, 0 failed (total 1)' \
        || return 1
    tr -d '\r' < "$thermal" | grep -Eq '^\[test\] PASS L[0-9]+:' || return 1
    ! tr -d '\r' < "$thermal" | grep -q '^FAIL' || return 1
    [ "$(tr -d '[:space:]' < "$status")" = 0 ] || return 1
    grep -qF 'Starting uart service' "$ec" || return 1
}

odp_e2e_finish_run() {
    local run_dir="$1" evidence_root="$2" outcome="$3" evidence file
    [ -d "$run_dir" ] && [ ! -L "$run_dir" ] || return 1
    evidence="$evidence_root/$(basename "$run_dir")"
    [ ! -L "$evidence" ] || return 1
    mkdir -p "$evidence"
    for file in result.txt thermal.log boot.log ec.log ec-qemu-stdout.log \
        ec-qemu-stderr.log qemu-status.txt firmware-build.log acpi-build.log \
        release.json secure-partition-manifest.dts secure_mm.log serial0.log; do
        [ ! -f "$run_dir/$file" ] || cp "$run_dir/$file" "$evidence/$file"
    done
    [ "$outcome" != success ] || rm -rf -- "$run_dir"
}

odp_e2e_stop_qemu() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    timeout 15 tail --pid="$pid" -f /dev/null >/dev/null 2>&1 || true
    kill -0 "$pid" 2>/dev/null || return 0
    kill -KILL "$pid" 2>/dev/null || true
}

odp_e2e_cleanup_processes() {
    odp_e2e_stop_qemu "$QEMU_PID"
    QEMU_PID=
    kill_ec_session
    EC_PID=
}

odp_e2e_reset_runner_log() {
    local log="$1"
    [ ! -L "$log" ] || return 1
    rm -f -- "$log"
}

odp_e2e_collect_runner_log() {
    local log="$1" run_dir="$2"
    [ -e "$log" ] || return 0
    [ -f "$log" ] && [ ! -L "$log" ] || return 1
    cp "$log" "$run_dir/secure_mm.log"
}

odp_e2e_run_qemu() {
    local overlay="$1" run_dir="$2" timeout_seconds="$3" ec_pty="$4" status
    local runner_log="$ODP_E2E_REPO_ROOT/mod/uefi/patina-qemu/secure_mm.log"
    rm -f "$run_dir/qemu.pid"
    odp_e2e_reset_runner_log "$runner_log" || return 1
    if timeout --foreground --signal=TERM --kill-after=15 "$timeout_seconds" \
        make -C "$ODP_E2E_REPO_ROOT/mod/uefi" run \
            PATH_TO_OS="$overlay" \
            EC_I2C_SOCK="$run_dir/ec-i2c.sock" \
            EC_GPIO_SOCK="$run_dir/ec-gpio.sock" \
            QEMU_DISPLAY=none \
            ODP_E2E_QEMU_PID_FILE="$run_dir/qemu.pid" \
            ODP_E2E_EC_PTY="$ec_pty" \
            ODP_E2E_SERIAL0_LOG="$run_dir/serial0.log" \
            > "$run_dir/boot.log" 2>&1; then
        status=0
    else
        status=$?
    fi
    [ ! -f "$run_dir/qemu.pid" ] || QEMU_PID="$(cat "$run_dir/qemu.pid")"
    odp_e2e_stop_qemu "$QEMU_PID"
    QEMU_PID=
    printf '%s\n' "$status" > "$run_dir/qemu-status.txt"
    odp_e2e_collect_runner_log "$runner_log" "$run_dir"
}

odp_e2e_execute() {
    local run_dir="$1" cache="$2" repo="$3" release="$4" timeout_seconds="$5"
    local release_json asset_id digest archive base base_before base_after acpi
    local manifest overlay ec_pty supplied_base="${WINDOWS_ACPI_E2E_BASE_IMAGE:-}"
    if [ -n "$supplied_base" ]; then
        case "$supplied_base" in
            /*) base="$supplied_base" ;;
            *) base="$ODP_E2E_REPO_ROOT/$supplied_base" ;;
        esac
        base="$(realpath -e -- "$base")" || return 1
        odp_e2e_safe_path "$base" "$ODP_E2E_REPO_ROOT" || return 1
        odp_e2e_validate_vhdx "$base" || return 1
        digest="sha256:$(sha256sum "$base" | awk '{print $1}')"
        odp_e2e_log "Using supplied WinVOS base: $(odp_e2e_host_path "$base")"
    else
        release_json="$run_dir/release.json"
        odp_e2e_log "Resolving WinVOS release asset"
        curl --fail --location --silent --show-error --retry 3 \
            "https://api.github.com/repos/$repo/releases/tags/$release" \
            --output "$release_json" || return 1
        IFS='|' read -r asset_id digest < <(
            odp_e2e_resolve_base_asset "$release_json" "$ODP_E2E_ASSET_NAME"
        ) || return 1
        archive="$cache/assets/${digest#sha256:}/$ODP_E2E_ASSET_NAME"
        odp_e2e_safe_path "$archive" "$cache" || return 1
        odp_e2e_log "Preparing verified WinVOS base"
        odp_e2e_download_asset \
            "https://api.github.com/repos/$repo/releases/assets/$asset_id" \
            "$digest" "$archive" || return 1
        base="$(odp_e2e_extract_base "$archive" "$digest" "$cache")" || return 1
    fi
    odp_e2e_validate_base_image "$base" "$digest" "$cache" || return 1
    base_before="$(sha256sum "$base" | awk '{print $1}')"

    odp_e2e_log "Building EC and UEFI firmware (log: $(odp_e2e_host_path "$run_dir/firmware-build.log"))"
    make -C "$ODP_E2E_REPO_ROOT" ec uefi > "$run_dir/firmware-build.log" 2>&1 \
        || return 1
    manifest="$ODP_E2E_SECURE_MANIFEST"
    odp_e2e_verify_secure_manifest "$manifest" || return 1
    cp "$manifest" "$run_dir/secure-partition-manifest.dts" || return 1
    odp_e2e_log "Compiling ACPI table (log: $(odp_e2e_host_path "$run_dir/acpi-build.log"))"
    acpi="$(odp_e2e_build_acpi "$run_dir")" || return 1
    odp_e2e_log "Preparing Windows overlay"
    overlay="$run_dir/overlay.qcow2"
    odp_e2e_make_overlay "$base" "$overlay" || return 1
    odp_e2e_inject_run_payload "$overlay" "$acpi" \
        "$ODP_E2E_PAYLOAD_DIR/run.cmd" "$ODP_E2E_PAYLOAD_DIR/thermal.test" \
        || return 1
    odp_e2e_set_startup_shell "$overlay" "$run_dir/winlogon.reg" || return 1

    export EC_I2C_SOCK="$run_dir/ec-i2c.sock"
    export EC_GPIO_SOCK="$run_dir/ec-gpio.sock"
    odp_e2e_log "Starting EC sidecar"
    start_ec_qemu \
        "$ODP_E2E_REPO_ROOT/mod/ec/platform/dev-qemu/target/riscv32imac-unknown-none-elf/release/dev-qemu" \
        "$run_dir/ec-qemu-stdout.log" "$run_dir/ec-qemu-stderr.log" \
        "$run_dir/ec.log" "$((timeout_seconds + 60))" || return 1
    ec_pty="$(discover_ec_pty "$run_dir/ec-qemu-stdout.log" \
        "$run_dir/ec-qemu-stderr.log")" || return 1
    odp_e2e_log \
        "Booting WinVOS (timeout ${timeout_seconds}s; log: $(odp_e2e_host_path "$run_dir/boot.log"); guest serial: $(odp_e2e_host_path "$run_dir/serial0.log"))"
    odp_e2e_run_qemu "$overlay" "$run_dir" "$timeout_seconds" "$ec_pty"
    odp_e2e_cleanup_processes
    odp_e2e_log "Extracting guest results"
    odp_e2e_extract_results "$overlay" "$run_dir" || return 1
    base_after="$(sha256sum "$base" | awk '{print $1}')"
    [ "$base_before" = "$base_after" ] || return 1
    odp_e2e_log "Verifying E2E result"
    odp_e2e_verify_result "$run_dir/result.txt" "$run_dir/thermal.log" \
        "$run_dir/ec.log" "$run_dir/qemu-status.txt"
}

odp_e2e_require_tools() {
    local tool missing=()
    for tool in curl defmt-print guestfish iasl jq make qemu-img \
        qemu-system-aarch64 qemu-system-riscv32 realpath sha256sum swtpm \
        tail timeout unzip virt-win-reg; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ "${#missing[@]}" -eq 0 ] \
        || odp_e2e_die "missing devcontainer tools: ${missing[*]}"
    require_ec_qemu_tools || exit 1
}

odp_e2e_main() {
    [ "$#" -eq 0 ] || odp_e2e_die "this runner takes no arguments; use make variables"
    [ "${IN_DEVCONTAINER:-0}" = 1 ] \
        || odp_e2e_die "run through 'make windows-acpi-e2e' from the repository root"
    local repo="${WINDOWS_ACPI_E2E_REPO:-OpenDevicePartnership/odp-platform-qemu-arm-virt}"
    local release="${WINDOWS_ACPI_E2E_RELEASE:-latest}"
    local timeout_seconds="${WINDOWS_ACPI_E2E_BOOT_TIMEOUT:-900}"
    local cache="${WINDOWS_ACPI_E2E_CACHE_DIR:-$(odp_e2e_default_cache_dir)}"
    local run_dir socket outcome=failure
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || odp_e2e_die "invalid base repository"
    [[ "$release" =~ ^[A-Za-z0-9_.-]+$ ]] || odp_e2e_die "invalid base release"
    [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || odp_e2e_die "invalid boot timeout"
    [[ "$ODP_E2E_HOST_ROOT" = /* ]] || odp_e2e_die "invalid host repository path"
    odp_e2e_safe_path "$cache" "$ODP_E2E_REPO_ROOT" || odp_e2e_die "unsafe cache path"
    mkdir -p "$cache"
    cache="$(realpath -e -- "$cache")" || odp_e2e_die "cannot resolve cache path"
    odp_e2e_safe_path "$cache" "$ODP_E2E_REPO_ROOT" || odp_e2e_die "unsafe cache path"
    ODP_E2E_CACHE_DIR="$cache"
    ODP_E2E_TMPDIR="$cache/work"
    export ODP_E2E_CACHE_DIR ODP_E2E_TMPDIR
    mkdir -p "$cache/work" "$cache/libguestfs-cache" "$cache/libguestfs-tmp" \
        "$cache/runs" "$cache/evidence"
    odp_e2e_require_tools
    odp_e2e_preflight_libguestfs || exit 1
    run_dir="$cache/runs/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    odp_e2e_safe_path "$run_dir" "$cache" || odp_e2e_die "unsafe run path"
    for socket in "$run_dir/ec-i2c.sock" "$run_dir/ec-gpio.sock"; do
        odp_e2e_safe_path "$socket" "$cache" || odp_e2e_die "unsafe socket path"
        odp_e2e_validate_socket_path "$socket" || exit 1
    done
    mkdir "$run_dir"
    trap odp_e2e_cleanup_processes EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    odp_e2e_log "e2e run artifacts: $(odp_e2e_host_path "$run_dir")"
    if odp_e2e_execute "$run_dir" "$cache" "$repo" "$release" "$timeout_seconds"; then
        outcome=success
    fi
    odp_e2e_cleanup_processes
    trap - EXIT INT TERM
    odp_e2e_finish_run "$run_dir" "$cache/evidence" "$outcome"
    [ "$outcome" = success ] || odp_e2e_die "Windows ACPI E2E failed"
    printf '%s\n' "$ODP_E2E_PASS_LINE"
}

if [ -n "${ODP_WINDOWS_ACPI_E2E_SOURCE_ONLY:-}" ]; then
    return 0 2>/dev/null || true
else
    odp_e2e_main "$@"
fi
