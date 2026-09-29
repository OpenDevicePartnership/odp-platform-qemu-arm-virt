# End-to-End Tests

## Overview

This directory contains the end-to-end (E2E) test suite for the QEMU `virt`
platform. Tests are compiled as UEFI applications that run inside QEMU and
exercise the EC Secure Partition services via FF-A Direct Request messages.

## Contents

| Path | Description |
| --- | --- |
| `ffa/` | FFA (Firmware Framework for Arm) helper library for test applications |
| `uart-logger/` | Minimal UART logger for UEFI test binaries |
| `test-support/` | Shared test utilities (partition discovery, request helpers) |
| `tests/thermal/` | Thermal service E2E test application |
| `tests/tpm/` | TPM service E2E test application |
| `coverage-plugin/` | QEMU TCG plugin for code coverage collection |
| `scripts/` | Post-processing scripts (e.g., PC trace to lcov conversion) |
| `startup.nsh` | Generic UEFI shell startup script (runs the single `.efi` staged on each per-test vdrive) |
| `Makefile` | Build and execution targets for the E2E test suite |

## Build

```bash
make -C e2e-tests build
```

## Run

Tests are executed via the top-level Makefile:

```bash
make e2e-test
```

This builds the UEFI test applications, launches QEMU with the platform
firmware, and verifies test results from the captured serial output.

For TimeAlarm alone, run `make ec uefi` followed by
`make -C e2e-tests relay-run-time-alarm`. This exercises clock set/readback,
timer countdown, AC/DC expired-status clearing, and policy 0/45 set/readback
through the SP and EC relay. For `NEVER` (`0xFFFFFFFF`), it checks setter
acceptance and the other timer's unchanged policy, not readback: the getter
uses the same value for failure. It does not qualify physical wake,
power-source switching, ASL, or asynchronous notifications.
