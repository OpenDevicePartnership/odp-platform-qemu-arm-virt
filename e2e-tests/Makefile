# E2E Tests for the EC Secure Partition
#
# SPDX-License-Identifier: MIT
#
# Builds Rust UEFI test applications, launches QEMU with the existing
# BIOS firmware, and executes tests against the secure partition.

SHELL := /bin/bash

include ../Common.mk

# Build output paths
TARGET_DIR := target/aarch64-unknown-uefi/release
THERMAL_EFI := $(TARGET_DIR)/thermal.efi
TPM_EFI := $(TARGET_DIR)/tpm.efi

# Timeout for QEMU execution (seconds)
QEMU_TIMEOUT ?= 180

# Bounds on the serial-link test (test-sp-ec-link). EC has done its useful work
# (boot, announce PTY, exchange a few messages) well within 30s, after which it
# spins in tight async loops that starve the host of CPU. Killing EC early lets
# host reach the UEFI shell and self-terminate within HOST_SERIAL_TIMEOUT.
EC_SERIAL_TIMEOUT  ?= 30
HOST_SERIAL_TIMEOUT ?= 60

# Virtual drive directory for UEFI Shell to find test EFI binaries
VDRIVE_DIR := Build/vdrive

# Tee QEMU serial output to stdout (auto-enabled in CI). Passed through to
# scripts/test-sp-services.sh, which owns the actual -serial / tee plumbing.
ifeq ($(CI),true)
SERIAL_TEE ?= 1
else
SERIAL_TEE ?= 0
endif

# Coverage plugin
COVERAGE_PLUGIN := Build/libcoverage.so
COVERAGE_LOG := Build/coverage.log
SP_ELF := ../mod/secure-services/platform/target/aarch64-unknown-none/coverage/qemu-ec-sp

# All test EFI binaries
TEST_EFIS := $(THERMAL_EFI) $(TPM_EFI)

# ------------------------------------------------------------
# Build all test EFI binaries
# ------------------------------------------------------------
.PHONY: all
all: build

.PHONY: build
build: builder-image
	$(call GROUP,Build E2E test binaries)
	@$(DC_RUN) -w e2e-tests -- cargo build --release
	$(call ENDGROUP)

# ------------------------------------------------------------
# Prepare the virtual FAT drive with test binaries + startup.nsh
# ------------------------------------------------------------
$(VDRIVE_DIR): build $(TEST_EFIS) startup.nsh
	rm -rf $(VDRIVE_DIR)
	mkdir -p $(VDRIVE_DIR)
	cp $(TEST_EFIS) $(VDRIVE_DIR)/
	cp startup.nsh $(VDRIVE_DIR)/startup.nsh

# ------------------------------------------------------------
# Run tests with timeout, capture output, report results
# ------------------------------------------------------------
# ------------------------------------------------------------
# Build the TCG coverage plugin (.so loaded by QEMU)
# ------------------------------------------------------------
$(COVERAGE_PLUGIN): builder-image
	$(call GROUP,Build coverage plugin)
	@$(DC_RUN) -w e2e-tests -- make -C coverage-plugin BUILD_DIR=../Build
	$(call ENDGROUP)

.PHONY: test-sp-services
test-sp-services: $(VDRIVE_DIR) $(COVERAGE_PLUGIN)
	@mkdir -p Build
	@echo "=== Running SP services E2E tests (timeout=$(QEMU_TIMEOUT)s) ==="
ifeq ($(SERIAL_TEE),1)
else
	@echo "    (serial output streaming to Build/test-output.log)"
endif
	$(call GROUP,SP services E2E tests)
	@$(DC_RUN) -- scripts/test-sp-services.sh \
		--bios-fv-dir $(BIOS_FV_DIR) \
		--build-dir e2e-tests/Build \
		--vdrive-dir e2e-tests/$(VDRIVE_DIR) \
		--coverage-plugin e2e-tests/$(COVERAGE_PLUGIN) \
		--coverage-log e2e-tests/$(COVERAGE_LOG) \
		--host-timeout $(QEMU_TIMEOUT) \
		--serial-tee $(SERIAL_TEE) \
		-- $(QEMU_COMMON_ARGS)
	$(call ENDGROUP)

# ------------------------------------------------------------
# Serial Communication Test
# ------------------------------------------------------------
# Launches EC QEMU with `-serial pty` (QEMU allocates a pseudo-tty
# and prints its path to stderr), parses the path, then launches
# host QEMU with a `serial` chardev opening that PTY as serial1.
# Verifies: PTY announced, EC booted, host started without errors.
#
# Caller (top-level Makefile) is responsible for ensuring `ec` and `uefi`
# are built; this target only runs the serial check.
.PHONY: test-sp-ec-link
test-sp-ec-link: | builder-image
	@mkdir -p Build
	@echo "=== Running SP+EC link smoke test (EC timeout=$(EC_SERIAL_TIMEOUT)s, host timeout=$(HOST_SERIAL_TIMEOUT)s) ==="
	$(call GROUP,SP+EC link smoke test)
	@$(DC_RUN) -- scripts/test-sp-ec-link.sh \
		--ec-elf $(EC_BINARY) \
		--bios-fv-dir $(BIOS_FV_DIR) \
		--build-dir e2e-tests/Build \
		--ec-timeout $(EC_SERIAL_TIMEOUT) \
		--host-timeout $(HOST_SERIAL_TIMEOUT) \
		-- $(QEMU_COMMON_ARGS)
	$(call ENDGROUP)

# ------------------------------------------------------------
# Generate coverage report from collected PCs
# ------------------------------------------------------------
.PHONY: coverage-report
coverage-report:
	$(call GROUP,Generate coverage report)
	@$(DC_RUN) -w e2e-tests -- python3 scripts/pcs-to-lcov.py \
		--elf $(SP_ELF) \
		--input $(COVERAGE_LOG) \
		--output Build/coverage.info \
		--source-prefix odp-secure-services \
		--source-prefix odp-platform-qemu-arm-virt
	@$(DC_RUN) -w e2e-tests -- genhtml Build/coverage.info \
		--ignore-errors source \
		--output-directory Build/coverage-html \
		--title 'EC Secure Partition Coverage'
	$(call ENDGROUP)

# ------------------------------------------------------------
# Clean build artifacts
# ------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf Build
	@$(DC_RUN) -w e2e-tests -- cargo clean
	@$(DC_RUN) -w e2e-tests -- make -C coverage-plugin clean
