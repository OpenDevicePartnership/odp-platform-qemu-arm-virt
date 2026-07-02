# odp-platform-qemu-arm-virt

[![Build](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/build.yml/badge.svg)](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/build.yml)
[![Check Submodules](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/check-submodules.yml/badge.svg)](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt/actions/workflows/check-submodules.yml)
[![LICENSE](https://img.shields.io/badge/License-MIT-blue)](./LICENSE)

This repo contains all the necessary content for working on QEMU `virt` (arm64) platform

## Quick Start Guide

This configuration has been tested on a windows running WSL Ubuntu 24.04 with Visual Studio Code.

After cloning the repository locally to WSL make sure from Visual Studio Code you have the WSL extension
installed to allow you to open code from terminal.

From the root folder run `code .` to start new VS code session.
When prompted select to re-open in a container which will setup all the required tools and packages.

From VS code menu run  `Terminal -> New Terminal` and run  `make all` from the root to rebuild all components.

To run QEMU with the image you generated you can run `make run` from the root folder

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
