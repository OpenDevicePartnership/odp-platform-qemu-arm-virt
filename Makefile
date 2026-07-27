# Primary Makefile for the ODP QEMU `virt` Platform firmware build system.
#
# SPDX-License-Identifier: MIT
#
include Common.mk

# ------------------------------------------------------------
# Default target — builds all artifacts (does not run tests).
# Use `make e2e-test` to run the full test suite (serial-link
# smoke test + e2e tests against the secure partition).
# ------------------------------------------------------------
all: mod
	$(MAKE) -C e2e-tests build

# ------------------------------------------------------------
# mod/ — secure-services, uefi, and ec live under mod/Makefile.
# Top-level just delegates so that mod-specific impl details
# (cargo invocations, build flavors, etc.) stay encapsulated.
# ------------------------------------------------------------
mod:
	$(MAKE) -C mod all

# Convenience aliases so `make ec`, `make uefi`, etc. still work from
# the top level. Each delegates to the like-named target in mod/Makefile.
secure-services secure-services-test uefi ec:
	$(MAKE) -C mod $@

# ------------------------------------------------------------
# Run QEMU using UEFI flash-only flow
# ------------------------------------------------------------
run:
	$(MAKE) -C mod/uefi run

# ------------------------------------------------------------
# Build OS image and boot it in QEMU
# ------------------------------------------------------------
run_os:
	$(MAKE) -C postbuild/os build/winvos.qcow2
	$(MAKE) -C mod/uefi run PATH_TO_OS=$(REPO_ROOT_IN_DEVCONTAINER)/postbuild/os/build/winvos.qcow2

# ------------------------------------------------------------
# Run the EC firmware (mod/ec/platform/dev-qemu) in RISC-V QEMU
# ------------------------------------------------------------
# Note: This is a separate QEMU instance from the ARM QEMU instance running UEFI+Windows.
#
# If wanting to connect the ARM QEMU and RISC-V QEMU instances over virtual bus,
# run `make run_ec` in a separate terminal window alongside `make run_os`.
#
# Order doesn't matter, the ARM QEMU instance will attempt to reconnect to the
# RISC-V QEMU instance periodically. However, of course if Windows attempts to
# communicate over the virtual bus while not connected to the virtual EC,
# it will fail.
run_ec:
	$(MAKE) -C mod run_ec

# ------------------------------------------------------------
# Run E2E tests against the secure partition
# ------------------------------------------------------------
# Two phases:
#   1. Two-QEMU EC-relay service e2es (Thermal, Battery, TimeAlarm) via
#      the sequential test-sp-relays aggregate: an EC sidecar + host SP
#      relaying each service's requests through MCTP. All use the default
#      secure-services build (no test-bypass) so the relay code path under
#      test matches what ships.
#   2. Single-QEMU TPM suite — rebuild secure-services with test-bypass
#      features, rebuild uefi with the test SP embedded, run TPM tests.
# Order matters: phase 2 clobbers the default secure-services binary,
# so all relay e2es (which need the non-test-bypass relay) must run first.
e2e-test: ec uefi
	$(MAKE) -C e2e-tests test-sp-relays
	$(MAKE) -C mod secure-services-test
	$(MAKE) -C mod uefi-only
	$(MAKE) -C e2e-tests test-sp-services

# ------------------------------------------------------------
# Clean everything
# ------------------------------------------------------------
clean:
	$(MAKE) -C mod clean
	$(MAKE) -C e2e-tests clean
	$(MAKE) -C postbuild/os clean
.PHONY: all mod secure-services secure-services-test uefi ec run run_ec e2e-test run_os clean
