# UEFI Platform Overlay

This directory holds the platform overlay that is prepended to the patina-qemu
edk2 `PACKAGES_PATH`. Files here can override or extend the platform build
without editing the `mod/uefi/patina-qemu` workspace.

## ACPI table build helper

Use `build_acpi_tables.sh` to build ACPI tables (`QemuArmVirtPkg/AcpiTables`)
and create a separate ODP firmware volume (`odp.fd`) for the QEMU arm-virt machine.

The script:
- Injects the ACPI tables component into the platform DSC
- Builds only `QemuArmVirtPkg/AcpiTables/AcpiTables.inf`
- Creates a standalone firmware volume containing the ACPI FFS
- Outputs `odp.fd` to the standard build directory

Prerequisites:
- `stuart_setup` and `stuart_update` must be run first
- UEFI platform build already initialized in patina-qemu

### Quick start

```sh
cd /workspaces/odp-platform-qemu-arm-virt
mod/uefi/platform/build_acpi_tables.sh
```

Output file:
```
mod/uefi/patina-qemu/Build/QemuArmVirtPkg/DEBUG_CLANGPDB/FV/odp.fd
```

### Using with QEMU arm-virt

Load the ODP ACPI tables as pflash unit 2:

```sh
qemu-system-aarch64 \
  -machine virt \
  -drive if=pflash,format=raw,unit=0,file=SECURE_FLASH0.fd \
  -drive if=pflash,format=raw,unit=1,file=QEMU_EFI.fd,readonly=on \
  -drive if=pflash,format=raw,unit=2,file=odp.fd,readonly=on \
  ...
```

When using test scripts, pass the ODP firmware volume to `set_host_pflash_tpm_args`:

```sh
source scripts/lib/host-qemu.sh
set_host_pflash_tpm_args "$BIOS_FV_DIR" "$SWTPM_SOCK" "mod/uefi/patina-qemu/Build/QemuArmVirtPkg/DEBUG_CLANGPDB/FV/odp.fd"
```

### Build configuration

To override the build target/toolchain (default: DEBUG/CLANGPDB):

```sh
BUILD_TARGET=RELEASE BUILD_TOOLCHAIN=GCC5 mod/uefi/platform/build_acpi_tables.sh
```

