# UEFI Firmware

## Overview

This module builds the UEFI firmware for the QEMU ARM Virt reference platform using
the Patina QEMU project. The firmware provides platform initialization, ACPI
tables, and boot services.

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
```

The build uses the devcontainer and Stuart (EDK II build system) to compile
the UEFI firmware image.

## Output

| Artifact | Description |
| --- | --- |
| `QEMU_EFI.fd` | UEFI firmware flash image for QEMU ARM virt |
