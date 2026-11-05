# UEFI Firmware

## Overview

This module builds Patina UEFI for ARM `virt` (`ARCH=aarch64`, the default)
and x64 Q35 (`ARCH=x86_64`). ARM includes the ODP ACPI overlay, secure
services, and EC wiring. Q35 uses Patina's existing configuration and runner
without an ODP ACPI overlay or secure services. The QEMU wrapper connects a
dedicated Q35 UART to the EC for Windows user-mode `--source serial` access;
HID-over-I2C and ODP ACPI service access remain ARM-only.

## Contents

| Path | Description |
| --- | --- |
| `patina-qemu/` | Patina QEMU UEFI firmware (submodule) |
| `platform/` | Platform-specific ACPI tables and configuration |
| `Makefile` | UEFI build targets |

## Build

This module is invoked from the root Makefile:

```bash
make uefi
make uefi ARCH=x86_64
```

The build uses the devcontainer and Stuart (EDK II build system) to compile
the UEFI firmware image.

## Output

| Artifact | Description |
| --- | --- |
| `QemuArmVirtPkg/DEBUG_CLANGPDB/FV/QEMU_EFI.fd` | ARM UEFI flash image |
| `QemuQ35Pkg/DEBUG_CLANGPDB/FV/QEMUQ35_CODE.fd` | Q35 read-only code flash |
| `QemuQ35Pkg/DEBUG_CLANGPDB/FV/QEMUQ35_VARS.fd` | Q35 writable variable store |

Paths are relative to `patina-qemu/Build/`.
