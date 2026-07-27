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
TPM_EFI := $(TARGET_DIR)/tpm.efi

# Two-QEMU EC-relay services. Each entry drives one generated vdrive +
# relay-run-<svc> target below. The test EFI basename is the service key
# with hyphens mapped to underscores (Cargo bin names), e.g.
# time-alarm -> time_alarm.efi.
RELAY_SERVICES := thermal battery time-alarm

# Timeout for QEMU execution (seconds)
QEMU_TIMEOUT ?= 180

# Bounds on the two-QEMU relay e2es (test-sp-ec-link). The EC sidecar is a
# passive responder: it must stay alive for the whole window the host might
# take to boot and relay its request. On a slow runner (CI) the host needs
# well over a minute to reach the UEFI shell and issue its request, so a
# short fixed EC lifetime races the host — the EC gets killed before the
# request arrives and the SP relay times out. Tie the EC lifetime to the
# host's own bound; the harness reaps the EC promptly via kill_ec_session
# once the host finishes, so this only acts as an upper backstop against a
# leaked EC process.
EC_SERIAL_TIMEOUT  ?= $(QEMU_TIMEOUT)

# Virtual drive directories for UEFI Shell to find test EFI binaries.
# Each test runs in its own vdrive so the shared startup.nsh finds exactly
# one binary (no parameterising the shell). Relay vdrives are generated
# from RELAY_SERVICES below as Build/vdrive-<svc>; the single-QEMU TPM
# path stages its own.
VDRIVE_TPM_DIR := Build/vdrive-tpm

# Shared generic UEFI shell startup script (runs the single .efi on the
# vdrive), reused by every per-test vdrive so new service tests don't each
# need their own startup script.
STARTUP_NSH := startup.nsh

# Stream QEMU serial output to stdout (auto-enabled in CI). Passed through
# to the test scripts; host-qemu.sh maps SERIAL_TEE=1 to QEMU's stdio
# chardev with a native logfile (stdout + TEST_OUTPUT), 0 to file only.
ifeq ($(CI),true)
SERIAL_TEE ?= 1
else
SERIAL_TEE ?= 0
endif

# Coverage plugin
COVERAGE_PLUGIN := Build/libcoverage.so
COVERAGE_LOG := Build/coverage.log
SP_ELF := ../mod/secure-services/platform/target/aarch64-unknown-none/coverage/qemu-ec-sp

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
# Prepare per-test virtual FAT drives with binaries + startup.nsh
# ------------------------------------------------------------
# make-vdrive <vdrive-dir> <efi-path>: stage a per-test FAT drive with the
# test binary + the shared generic startup.nsh. New service tests add one
# more $(call make-vdrive,...) — no new startup script.
define make-vdrive
rm -rf $(1)
mkdir -p $(1)
cp $(2) $(1)/
cp $(STARTUP_NSH) $(1)/startup.nsh
endef

$(VDRIVE_TPM_DIR): build $(TPM_EFI) $(STARTUP_NSH)
	$(call make-vdrive,$(VDRIVE_TPM_DIR),$(TPM_EFI))

# Generate one vdrive rule per relay service: Build/vdrive-<svc> stages
# <svc>'s EFI (hyphens -> underscores) with the shared startup.nsh.
define relay-vdrive-rule
Build/vdrive-$(1): build $(TARGET_DIR)/$(subst -,_,$(1)).efi $(STARTUP_NSH)
	$$(call make-vdrive,Build/vdrive-$(1),$(TARGET_DIR)/$(subst -,_,$(1)).efi)
endef
$(foreach svc,$(RELAY_SERVICES),$(eval $(call relay-vdrive-rule,$(svc))))

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
test-sp-services: $(VDRIVE_TPM_DIR) $(COVERAGE_PLUGIN)
	@mkdir -p Build
	@echo "=== Running SP services E2E tests (timeout=$(QEMU_TIMEOUT)s) ==="
ifeq ($(SERIAL_TEE),1)
else
	@echo "    (serial output streaming to Build/test-output.log)"
endif
	$(call GROUP,SP services E2E tests)
	@$(DC_RUN) -- scripts/test-sp-services.sh \
		$(BIOS_FV_DIR) \
		e2e-tests/Build \
		e2e-tests/$(VDRIVE_TPM_DIR) \
		e2e-tests/$(COVERAGE_PLUGIN) \
		e2e-tests/$(COVERAGE_LOG) \
		$(QEMU_TIMEOUT) \
		$(SERIAL_TEE) \
		-- $(QEMU_COMMON_ARGS)
	$(call ENDGROUP)

# ------------------------------------------------------------
# Two-QEMU EC-relay E2E tests (test-sp-ec-link)
# ------------------------------------------------------------
# Launches EC QEMU with `-serial pty` (QEMU allocates a pseudo-tty
# and prints its path to stderr), parses the path, then delegates
# host QEMU launch + result parsing to the same runner test-sp-services
# uses (scripts/lib/host-qemu.sh::run_host_efi_and_parse_results).
# Asserts the [PASS] line originated from the EC over the MCTP relay.
#
# Caller (top-level Makefile) is responsible for ensuring `ec` and `uefi`
# are built; these targets only run the e2e check.
#
# run-sp-ec-link <vdrive-dir>: launch the EC sidecar + host SP two-QEMU run
# against the given per-test vdrive. Shared by every relay service test.
define run-sp-ec-link
@$(DC_RUN) -- scripts/test-sp-ec-link.sh \
	$(EC_BINARY) \
	$(BIOS_FV_DIR) \
	e2e-tests/Build \
	e2e-tests/$(1) \
	e2e-tests/$(COVERAGE_PLUGIN) \
	e2e-tests/$(COVERAGE_LOG) \
	$(EC_SERIAL_TIMEOUT) \
	$(QEMU_TIMEOUT) \
	$(SERIAL_TEE) \
	-- $(QEMU_COMMON_ARGS)
endef

# Generate relay-run-<svc> for each RELAY_SERVICES entry. Each runs one
# service in its own EC + host QEMU pair against Build/vdrive-<svc>.
define relay-run-rule
.PHONY: relay-run-$(1)
relay-run-$(1): Build/vdrive-$(1) $(COVERAGE_PLUGIN) | builder-image
	@mkdir -p Build
	@echo "=== Running two-QEMU $(1) e2e (EC timeout=$$(EC_SERIAL_TIMEOUT)s, host timeout=$$(QEMU_TIMEOUT)s) ==="
	$$(call GROUP,Two-QEMU $(1) e2e)
	$$(call run-sp-ec-link,Build/vdrive-$(1))
	$$(call ENDGROUP)
endef
$(foreach svc,$(RELAY_SERVICES),$(eval $(call relay-run-rule,$(svc))))

# Sequential aggregate over all relay services, used once by the top-level
# `e2e-test`. Recursive per-service sub-makes run strictly one at a time
# (even under `make -j`), so concurrent QEMU pairs can never collide on the
# shared Build/ logs, swtpm state, or coverage.log.
.PHONY: test-sp-relays
test-sp-relays:
	@set -e; for svc in $(RELAY_SERVICES); do \
		$(MAKE) relay-run-$$svc; \
	done

# Compatibility aliases for the historical per-service target names.
.PHONY: test-sp-ec-link test-sp-ec-link-battery test-sp-ec-link-time-alarm
test-sp-ec-link:            relay-run-thermal
test-sp-ec-link-battery:    relay-run-battery
test-sp-ec-link-time-alarm: relay-run-time-alarm

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
