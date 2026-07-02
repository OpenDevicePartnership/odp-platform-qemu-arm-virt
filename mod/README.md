# Modules

## Overview

This directory contains the platform firmware modules that are built and
combined to produce the final QEMU ARM Virt firmware image. Each subdirectory
represents a distinct firmware component with its own build system.

## Contents

| Path | Description |
| --- | --- |
| `ec/` | Embedded Controller firmware (submodule: odp-embedded-controller) |
| `secure-services/` | EC Secure Partition service (FF-A, TPM CRB, thermal) |
| `uefi/` | UEFI firmware (Patina QEMU platform, ACPI tables) |
| `Makefile` | Orchestrates builds for all modules |

## Build

All modules are built from the root Makefile:

```bash
make mod
```

Individual modules can be built directly:

```bash
make secure-services
make uefi
make ec
```
