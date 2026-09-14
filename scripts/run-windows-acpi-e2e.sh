#!/usr/bin/env bash
# Build and run the Windows ACPI end-to-end test.
#
# SPDX-License-Identifier: MIT

set -euo pipefail

ODP_E2E_PASS_LINE='PASS: Windows ACPI E2E'
ODP_E2E_MIN_BUILD=28000
ODP_E2E_ASSET_NAME='os-image.zip'
ODP_E2E_IMAGE_NAME='os-image.vhdx'
ODP_E2E_SERVICE=thermal
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

odp_e2e_select_service() {
    ODP_E2E_SERVICE="$1"
    case "$ODP_E2E_SERVICE" in
        thermal) return 0 ;;
        ucsi) ;;
        *) odp_e2e_error "invalid WINDOWS_ACPI_E2E_SERVICE: $1 (expected thermal or ucsi)"; return 1 ;;
    esac
    local adapter="$ODP_E2E_PAYLOAD_DIR/adapters/ucsi" package previous
    ODP_E2E_REQUIRED_DRIVERS=()
    [ -f "$adapter/drivers.txt" ] && [ -f "$adapter/secure-uuid.txt" ] || {
        odp_e2e_error "missing UCSI driver or UUID contract"
        return 1
    }
    while IFS= read -r package || [ -n "$package" ]; do
        package="${package%$'\r'}"
        case "$package" in ''|\#*) continue ;; esac
        [[ "$package" =~ ^driver-[a-z][a-z0-9_]*-ARM64-Release$ ]] || {
            odp_e2e_error "invalid UCSI ARM64 driver package: $package"; return 1;
        }
        for previous in "${ODP_E2E_REQUIRED_DRIVERS[@]}"; do
            [ "$package" != "$previous" ] || {
                odp_e2e_error "duplicate UCSI driver package: $package"
                return 1
            }
        done
        ODP_E2E_REQUIRED_DRIVERS+=("$package")
    done < "$adapter/drivers.txt"
    [ "${#ODP_E2E_REQUIRED_DRIVERS[@]}" -eq 3 ] || {
        odp_e2e_error "UCSI requires exactly three ARM64 driver packages"
        return 1
    }
    ODP_E2E_SECURE_UUID="$(tr -d '\r' < "$adapter/secure-uuid.txt")"
    [[ "$ODP_E2E_SECURE_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
        odp_e2e_error "invalid UCSI secure UUID contract"
        return 1
    }
}

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

odp_e2e_verify_arm64_pe() {
    local binary="$1" log="$2"
    if ! llvm-readobj --file-headers "$binary" > "$log" 2>&1 \
        || ! grep -qx 'Format: COFF-ARM64' "$log" \
        || ! grep -qx 'ImageOptionalHeader {' "$log" \
        || ! grep -q 'Machine: IMAGE_FILE_MACHINE_ARM64 (0xAA64)' "$log"; then
        odp_e2e_error "not an ARM64 PE image: $binary (details: $log)"
        return 1
    fi
}

odp_e2e_validate_ucsi_drivers() {
    local base="$1" run_dir="$2" store package stem directory found output
    local repository=/Windows/System32/DriverStore/FileRepository
    store="$(odp_e2e_guestfish --ro --format=vhdx -a "$base" -i ls "$repository")" || {
        odp_e2e_error "cannot inspect Windows DriverStore"; return 1;
    }
    printf '%s\n' "$store" > "$run_dir/driver-store.txt"
    : > "$run_dir/driver-inventory.txt"
    for package in "${ODP_E2E_REQUIRED_DRIVERS[@]}"; do
        stem="${package#driver-}"
        stem="${stem%-ARM64-Release}"
        # The ectest_kmdf project packages ectest.inf and ectest.sys.
        stem="${stem%_kmdf}"
        found=0
        while IFS= read -r directory; do
            [[ "${directory,,}" =~ ^${stem}[.]inf_arm64_[0-9a-f]+$ ]] || continue
            found=1
            output="$run_dir/drivers/$directory"
            mkdir -p "$output"
            if ! odp_e2e_guestfish --ro --format=vhdx -a "$base" -i \
                download "$repository/$directory/$stem.inf" "$output/$stem.inf" \
                : download "$repository/$directory/$stem.sys" "$output/$stem.sys" \
                || [ ! -s "$output/$stem.inf" ] \
                || ! odp_e2e_verify_arm64_pe "$output/$stem.sys" "$output/pe.txt"; then
                odp_e2e_error "unsuitable UCSI driver package: $package ($repository/$directory)"
                return 1
            fi
            printf '%s: %s/%s\n' "$package" "$repository" "$directory" \
                >> "$run_dir/driver-inventory.txt"
            (cd "$output" && sha256sum "$stem.inf" "$stem.sys") \
                >> "$run_dir/driver-inventory.txt" || return 1
        done <<< "$store"
        [ "$found" -eq 1 ] || {
            odp_e2e_error "base image is missing required ARM64 package: $package"
            return 1
        }
    done
}

odp_e2e_build_ucsi_smoke() {
    local run_dir="$1" manifest target executable
    manifest="$ODP_E2E_PAYLOAD_DIR/adapters/ucsi/smoke/Cargo.toml"
    if ! (cd "$(dirname "$manifest")" && \
        cargo xwin build --locked --release --target aarch64-pc-windows-msvc \
            --manifest-path "$manifest") > "$run_dir/smoke-build.log" 2>&1; then
        odp_e2e_error "current UCSI smoke build failed (details: $(odp_e2e_host_path "$run_dir/smoke-build.log"))"
        return 1
    fi
    target="$(cd "$(dirname "$manifest")" && \
        cargo metadata --locked --no-deps --format-version 1 --manifest-path "$manifest" \
            2>> "$run_dir/smoke-build.log" | jq -er '.target_directory')" || return 1
    executable="$target/aarch64-pc-windows-msvc/release/smoke.exe"
    odp_e2e_verify_arm64_pe "$executable" "$run_dir/smoke-pe.txt" || return 1
    llvm-readobj --coff-imports "$executable" > "$run_dir/smoke-imports.txt" 2>&1 || {
        odp_e2e_error "cannot inspect UCSI smoke imports (details: $(odp_e2e_host_path "$run_dir/smoke-imports.txt"))"
        return 1
    }
    if grep -qiE '^[[:space:]]*Name: VCRUNTIME140[.]dll[[:space:]]*$' "$run_dir/smoke-imports.txt"; then
        odp_e2e_error "UCSI smoke imports VCRUNTIME140.dll, unavailable in WinVOS; build with crt-static"
        return 1
    fi
    cp "$executable" "$run_dir/smoke.exe" || return 1
    (cd "$run_dir" && sha256sum smoke.exe > smoke.exe.sha256) || return 1
    printf '%s\n' "$run_dir/smoke.exe"
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
    local manifest="$1" tuple='<0xa76df531 0x724d3c59 0xc78fb3a4 0x73c01a17>'
    local hex word offset
    if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
        odp_e2e_error "generated secure partition manifest missing: $(odp_e2e_host_path "$manifest")"
        return 1
    fi
    if [ "$ODP_E2E_SERVICE" = ucsi ]; then
        hex="${ODP_E2E_SECURE_UUID//-/}"
        tuple='<'
        for ((offset = 0; offset < 32; offset += 8)); do
            word="${hex:offset:8}"
            tuple+="0x${word:6:2}${word:4:2}${word:2:2}${word:0:2} "
        done
        tuple="${tuple% }>"
    fi
    grep -Eq \
        "^[[:space:]]*(uuid[[:space:]]*=[[:space:]]*)?$tuple[,;][[:space:]]*$" \
        "$manifest" || {
        odp_e2e_error "generated secure partition manifest $ODP_E2E_SERVICE UUID word tuple mismatch: $(odp_e2e_host_path "$manifest")"
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
    local overlay="$1" acpi="$2" run_cmd="$3" payload="$4" destination=thermal.test
    [ "$ODP_E2E_SERVICE" != ucsi ] || destination=smoke.exe
    odp_e2e_guestfish -a "$overlay" -i \
        mkdir-p /odp-e2e \
        : rm-f /odp-e2e/result.txt \
        : rm-f /odp-e2e/thermal.log \
        : rm-f /odp-e2e/ucsi.log \
        : upload "$acpi" /Windows/System32/ACPITABL.dat \
        : upload "$run_cmd" /odp-e2e/run.cmd \
        : upload "$payload" "/odp-e2e/$destination"
}

odp_e2e_set_startup_shell() {
    local overlay="$1" registry="$2"
    cat > "$registry" <<EOF
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon]
"Shell"="cmd.exe /c C:\\\\odp-e2e\\\\run.cmd $ODP_E2E_SERVICE"
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
    local overlay="$1" run_dir="$2" status=0
    odp_e2e_guestfish --ro -a "$overlay" -i \
        download /odp-e2e/result.txt "$run_dir/result.txt" || status=1
    odp_e2e_guestfish --ro -a "$overlay" -i \
        download "/odp-e2e/$ODP_E2E_SERVICE.log" "$run_dir/$ODP_E2E_SERVICE.log" || status=1
    return "$status"
}

odp_e2e_verify_result() {
    local result="$1" log="$2" runtime="$3" status="$4" file
    for file in "$result" "$log" "$runtime" "$status"; do
        [ -f "$file" ] || { odp_e2e_error "missing result evidence: $file"; return 1; }
    done
    if [ "$(tr -d '\r' < "$result")" != "$ODP_E2E_PASS_LINE" ] \
        || [ "$(tr -d '[:space:]' < "$status")" != 0 ] \
        || tr -d '\r' < "$log" | grep -q '^FAIL'; then
        odp_e2e_error "guest result or QEMU exit indicates failure"
        return 1
    fi
    if [ "$ODP_E2E_SERVICE" = ucsi ]; then
        tr -d '\r' < "$log" | grep -qxF 'UCSI SUMMARY: 4 passed, 0 failed' || {
            odp_e2e_error "missing complete UCSI success summary"; return 1;
        }
        grep -Eq "msg_loop: request: MsgSendDirectReq2\\(DirectMessage \\{.*uuid: $ODP_E2E_SECURE_UUID," "$runtime" || {
            odp_e2e_error "missing current-run UCSI secure request trace"; return 1;
        }
    else
        tr -d '\r' < "$log" | grep -qxF \
            '[test] SUMMARY C:\odp-e2e\thermal.test: 1 passed, 0 failed (total 1)' \
            && tr -d '\r' < "$log" | grep -Eq '^\[test\] PASS L[0-9]+:' \
            && grep -qF 'Starting uart service' "$runtime" || {
            odp_e2e_error "missing thermal success summary or live EC marker"; return 1;
        }
    fi
}

odp_e2e_finish_run() {
    local run_dir="$1" evidence_root="$2" outcome="$3" evidence file
    [ -d "$run_dir" ] && [ ! -L "$run_dir" ] || return 1
    evidence="$evidence_root/$(basename "$run_dir")"
    [ ! -L "$evidence" ] || return 1
    mkdir -p "$evidence" || return 1
    for file in result.txt thermal.log ucsi.log boot.log ec.log ec-qemu-stdout.log \
        ec-qemu-stderr.log qemu-status.txt firmware-build.log acpi-build.log \
        release.json secure-partition-manifest.dts secure_mm.log serial0.log \
        smoke-build.log smoke-pe.txt smoke-imports.txt smoke.exe smoke.exe.sha256 \
        base-image.txt image-validation.txt driver-store.txt driver-inventory.txt \
        qemu-command.txt; do
        [ ! -f "$run_dir/$file" ] || cp "$run_dir/$file" "$evidence/$file" || return 1
    done
    for file in acpi drivers; do
        [ ! -d "$run_dir/$file" ] || cp -r "$run_dir/$file" "$evidence/$file" || return 1
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
    local launch=(make) connections=()
    local runner_log="$ODP_E2E_REPO_ROOT/mod/uefi/patina-qemu/secure_mm.log"
    if [ "$ODP_E2E_SERVICE" = ucsi ]; then
        launch=(env -u ODP_E2E_EC_PTY make)
        connections=(EC_I2C_SOCK= EC_GPIO_SOCK= EC_UART_SOCK=)
    else
        connections=(EC_I2C_SOCK="$run_dir/ec-i2c.sock"
            EC_GPIO_SOCK="$run_dir/ec-gpio.sock" ODP_E2E_EC_PTY="$ec_pty")
    fi
    launch+=(-C "$ODP_E2E_REPO_ROOT/mod/uefi" run PATH_TO_OS="$overlay"
        "${connections[@]}" QEMU_DISPLAY=none
        ODP_E2E_QEMU_PID_FILE="$run_dir/qemu.pid"
        ODP_E2E_SERIAL0_LOG="$run_dir/serial0.log")
    printf '%q ' "${launch[@]}" > "$run_dir/qemu-command.txt"
    printf '\n' >> "$run_dir/qemu-command.txt"
    rm -f "$run_dir/qemu.pid"
    odp_e2e_reset_runner_log "$runner_log" || return 1
    if timeout --foreground --signal=TERM --kill-after=15 "$timeout_seconds" \
        "${launch[@]}" \
            > "$run_dir/boot.log" 2>&1; then
        status=0
    else
        status=$?
    fi
    [ ! -f "$run_dir/qemu.pid" ] || QEMU_PID="$(cat "$run_dir/qemu.pid")"
    odp_e2e_stop_qemu "$QEMU_PID"
    QEMU_PID=
    printf '%s\n' "$status" > "$run_dir/qemu-status.txt"
    odp_e2e_collect_runner_log "$runner_log" "$run_dir" || return 1
    # Hafnium emits the SP's FFA_CONSOLE_LOG on UART0.
    if [ "$ODP_E2E_SERVICE" = ucsi ] && [ -f "$run_dir/serial0.log" ]; then
        cat "$run_dir/serial0.log" >> "$run_dir/boot.log"
    fi
}

odp_e2e_execute() {
    local run_dir="$1" cache="$2" repo="$3" release="$4" timeout_seconds="$5"
    local release_json asset_id digest archive base base_before base_after acpi
    local manifest overlay ec_pty= payload="$ODP_E2E_PAYLOAD_DIR/thermal.test"
    local supplied_base="${WINDOWS_ACPI_E2E_BASE_IMAGE:-}" targets=(ec uefi)
    if [ "$ODP_E2E_SERVICE" = ucsi ]; then
        [ -z "${MAKEFILES:-}" ] || {
            odp_e2e_error "UCSI cannot inherit MAKEFILES that may restore EC connections"
            return 1
        }
        case "${MAKEFLAGS:-} ${MFLAGS:-} ${MAKEOVERRIDES:-} ${GNUMAKEFLAGS:-}" in
            *ODP_E2E_EC_PTY*)
                odp_e2e_error "UCSI cannot inherit a Make ODP_E2E_EC_PTY override"
                return 1 ;;
        esac
        targets=(uefi)
    fi
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
    printf 'base=%s\nasset-digest=%s\nimage-sha256=%s\n' \
        "$(odp_e2e_host_path "$base")" "$digest" "$base_before" > "$run_dir/base-image.txt"
    cp "$cache/validated/${digest#sha256:}" "$run_dir/image-validation.txt" || return 1
    if [ "$ODP_E2E_SERVICE" = ucsi ]; then
        odp_e2e_validate_ucsi_drivers "$base" "$run_dir" || return 1
        payload="$(odp_e2e_build_ucsi_smoke "$run_dir")" || return 1
    fi

    odp_e2e_log "Building ${targets[*]} firmware (log: $(odp_e2e_host_path "$run_dir/firmware-build.log"))"
    make -C "$ODP_E2E_REPO_ROOT" "${targets[@]}" > "$run_dir/firmware-build.log" 2>&1 \
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
        "$ODP_E2E_PAYLOAD_DIR/run.cmd" "$payload" \
        || return 1
    odp_e2e_set_startup_shell "$overlay" "$run_dir/winlogon.reg" || return 1

    if [ "$ODP_E2E_SERVICE" = thermal ]; then
        export EC_I2C_SOCK="$run_dir/ec-i2c.sock"
        export EC_GPIO_SOCK="$run_dir/ec-gpio.sock"
        odp_e2e_log "Starting EC sidecar"
        start_ec_qemu \
            "$ODP_E2E_REPO_ROOT/mod/ec/platform/dev-qemu/target/riscv32imac-unknown-none-elf/release/dev-qemu" \
            "$run_dir/ec-qemu-stdout.log" "$run_dir/ec-qemu-stderr.log" \
            "$run_dir/ec.log" "$((timeout_seconds + 60))" || return 1
        ec_pty="$(discover_ec_pty "$run_dir/ec-qemu-stdout.log" \
            "$run_dir/ec-qemu-stderr.log")" || return 1
    fi
    odp_e2e_log \
        "Booting WinVOS (timeout ${timeout_seconds}s; log: $(odp_e2e_host_path "$run_dir/boot.log"); guest serial: $(odp_e2e_host_path "$run_dir/serial0.log"))"
    odp_e2e_run_qemu "$overlay" "$run_dir" "$timeout_seconds" "$ec_pty" || return 1
    odp_e2e_cleanup_processes
    odp_e2e_log "Extracting guest results"
    odp_e2e_extract_results "$overlay" "$run_dir" || return 1
    base_after="$(sha256sum "$base" | awk '{print $1}')"
    [ "$base_before" = "$base_after" ] || return 1
    odp_e2e_log "Verifying E2E result"
    local runtime="$run_dir/ec.log"
    [ "$ODP_E2E_SERVICE" != ucsi ] || runtime="$run_dir/serial0.log"
    odp_e2e_verify_result "$run_dir/result.txt" "$run_dir/$ODP_E2E_SERVICE.log" \
        "$runtime" "$run_dir/qemu-status.txt"
}

odp_e2e_require_tools() {
    local tool missing=()
    local tools=(curl guestfish iasl jq make qemu-img qemu-system-aarch64 \
        realpath sha256sum swtpm tail timeout unzip virt-win-reg)
    [ "$ODP_E2E_SERVICE" != ucsi ] || tools+=(cargo cargo-xwin llvm-readobj)
    for tool in "${tools[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    [ "${#missing[@]}" -eq 0 ] \
        || odp_e2e_die "missing devcontainer tools: ${missing[*]}"
    if [ "$ODP_E2E_SERVICE" = thermal ]; then
        require_ec_qemu_tools || exit 1
    fi
}

odp_e2e_main() {
    [ "$#" -eq 0 ] || odp_e2e_die "this runner takes no arguments; use make variables"
    odp_e2e_select_service "${WINDOWS_ACPI_E2E_SERVICE-thermal}" || exit 1
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
    if [ "$ODP_E2E_SERVICE" = thermal ]; then
        for socket in "$run_dir/ec-i2c.sock" "$run_dir/ec-gpio.sock"; do
            odp_e2e_safe_path "$socket" "$cache" || odp_e2e_die "unsafe socket path"
            odp_e2e_validate_socket_path "$socket" || exit 1
        done
    fi
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

odp_e2e_main "$@"
