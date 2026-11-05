# odp-platform-qemu-arm-virt

[![Build](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/build.yml/badge.svg)](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/build.yml)
[![Check Submodules](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/check-submodules.yml/badge.svg)](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/check-submodules.yml)
[![LICENSE](https://img.shields.io/badge/License-MIT-blue)](./LICENSE)

This repo integrates the QEMU ARM `virt` platform and x64 Q35 firmware
and Windows Validation OS (WinVOS). ARM includes ODP secure services and EC
co-simulation; Q35 supports direct EC serial access through the Windows inbox
serial driver, without ODP ACPI service or HID-over-I2C support.

## Documentation

Project documentation is maintained in the [`docs/`](docs/src/introduction.md)
mdBook and published to
[GitHub Pages](https://opendevicepartnership.github.io/odp-platform-qemu-arm-virt/).
Build it locally with `make docs`.

## Quick Start Guide

This configuration has been tested on a windows running WSL Ubuntu 24.04 with Visual Studio Code.

After cloning the repository locally to WSL make sure from Visual Studio Code you have the WSL extension
installed to allow you to open code from terminal.

From the root folder run `code .` to start new VS code session.
When prompted select to re-open in a container which will setup all the required tools and packages.

From VS code menu run  `Terminal -> New Terminal` and run  `make all` from the root to rebuild all components.

To run QEMU with the image you generated you can run `make run` from the root folder

### Architecture Selection

`ARCH` defaults to `aarch64`. Use the same targets for either architecture:

| Command | ARM `virt` | x64 Q35 |
| --- | --- | --- |
| Build | `make all` | `make all ARCH=x86_64` |
| Boot firmware | `make run` | `make run ARCH=x86_64` |
| Boot WinVOS | `make run_os` | `make run_os ARCH=x86_64` |

An exported selector also works, for example `export ARCH=x86_64` followed
by `make all`. Build the selected firmware before running it. Switching
platforms sequentially does not require `make clean`; simultaneous builds in
one checkout are not supported. `make clean` remains global.

On ARM, `all` builds secure services, EC firmware, UEFI, and E2E applications.
On x64 it builds only Patina Q35 UEFI, without the ARM ACPI overlay.
Service builds and functional service tests reject `ARCH=x86_64`.
The RISC-V EC remains a separate `make run_ec` sidecar.

The VS Code `build`, `run`, `run_os`, and `run_os_windowed` tasks prompt for an
architecture. The two combined OS/EC tasks also prompt for an architecture;
the `e2e-test` task is ARM-pinned. `clean` never prompts.

OS downloads and writable disks are separated under
`postbuild/os/prebuilt/<arch>/` and `postbuild/os/build/<arch>/`.
The image workflow produces `os-image.zip` and `os-image-x86_64.zip`,
each containing `os-image.vhdx`. Matching ODP drivers are staged in both images,
and test apps are bundled at `C:\ectest`. Q35 direct serial access uses the inbox
serial driver; ODP ACPI service access remains ARM-only. See the
[OS image documentation](postbuild/os/README.md) for image preparation and
publication prerequisites.

To run end-to-end tests against the secure partition: `make e2e-test`
(builds everything, runs the EC↔host serial-link smoke test, then
launches QEMU and runs the full e2e test suite).
See [docs/e2e-tests.md](docs/e2e-tests.md) for details.

After tests run, a code coverage report for the secure partition is generated
with `make -C e2e-tests coverage-report` (outputs to `e2e-tests/Build/coverage-html/`).

Each sub folder has its own Makefile script to build each subcomponent.

## Folder Structure and Content

```
odp-platform-qemu-arm-virt
  |- .github/           Github automation support (CI/CD)
  |- .devcontainer/     Devcontainer definitions
  |- mod/               ACPI, UEFI, TF-A, Hafnium and secure service modules
  |- docs/              Documentation
  |- e2e-tests/         End-to-end tests for secure partition services
  |- ec/                EC MCU code
  |- postbuild/         Scripts for stitching SPINOR and OS images together
  |- scripts/           Build & dev helper scripts (e.g. dc-run.sh devcontainer dispatcher)
  |- common/            Tools, utilities and common code
  |- Makefile           Root makefile to make all components
  |- README.md          Quickstart file for each folder level
```
