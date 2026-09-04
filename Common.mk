# Shared variables and targets included by all Makefiles in the ODP QEMU `virt` Platform build system.
#
# SPDX-License-Identifier: MIT
#

REPO_ROOT_IN_HOST := $(shell realpath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT_IN_DEVCONTAINER := /workspaces/$(shell basename $(REPO_ROOT_IN_HOST))
DEVCONTAINER_WORKSPACE_FLAGS := \
	--workspace-folder $(REPO_ROOT_IN_HOST) \
	--remote-env GIT_COMMITTER_NAME=vscode \
	--remote-env GIT_COMMITTER_EMAIL=vscode@example.com
DEVCONTAINER_FILES := \
	$(REPO_ROOT_IN_HOST)/.devcontainer/devcontainer.json \
	$(REPO_ROOT_IN_HOST)/.devcontainer/Dockerfile
DEVCONTAINER_STAMP := $(REPO_ROOT_IN_HOST)/.devcontainer-up.stamp
ifeq ($(IN_DEVCONTAINER),1)
BUILDER_IMAGE_DEPS :=
else
BUILDER_IMAGE_DEPS := $(DEVCONTAINER_STAMP)
endif

# ------------------------------------------------------------
# CI log grouping (GitHub Actions foldable sections)
# ------------------------------------------------------------
ifeq ($(CI),true)
GROUP = @echo '::group::$(1)'
ENDGROUP = @echo '::endgroup::'
else
GROUP =
ENDGROUP =
endif

# ------------------------------------------------------------
# Common QEMU machine / SMBIOS / device flags
# ------------------------------------------------------------
# Shared across the top-level Makefile, e2e-tests/Makefile, and
# os-image/Makefile.  Individual targets append pflash drives,
# serial, display, and any extra device flags.
BIOS_FV_DIR := mod/uefi/patina-qemu/Build/QemuArmVirtPkg/DEBUG_CLANGPDB/FV

# Path to the EC firmware binary (relative to repo root). Built by
# `make -C mod ec`. Top-level recipes (e2e-test) reference it without
# owning the build rule.
EC_BINARY := mod/ec/platform/dev-qemu/target/riscv32imac-unknown-none-elf/release/dev-qemu

# Shared endpoints for the ARM host and RISC-V EC QEMU instances. The EC owns
# the socket servers; the host connects as a client. Command-line overrides
# propagate through recursive Make invocations.
EC_I2C_SOCK ?= /tmp/qemu-ec-i2c.sock
EC_GPIO_SOCK ?= /tmp/qemu-ec-gpio.sock
EC_UART_SOCK ?= /tmp/qemu-ec-uart.sock

QEMU_COMMON_ARGS := \
	-semihosting -cpu max,sve=off,sme=off -smp 4 \
	-machine virt,secure=on,virtualization=on,gic-version=3,mte=on,iommu=smmuv3 \
	-global driver=cfi.pflash01,property=secure,value=on -m 4G \
	-net none \
	-smbios type=0,vendor="Patina",version="v1.0.2",date="03/06/2026",uefi=on \
	-smbios type=1,manufacturer="OpenDevicePartnership",product="QEMU VIRT",family="QEMU",version="10.0.0",serial="42-42-42-42",uuid=99fb60e2-181c-413a-a3cf-0a5fea8d87b0 \
	-smbios type=3,manufacturer="OpenDevicePartnership",serial="42-42-42-42",asset="VIRT",sku="VIRT",version="" \
	-device qemu-xhci,id=usb -device usb-mouse,id=input0,bus=usb.0,port=1 \
	-device usb-kbd,id=input1,bus=usb.0,port=2

# ------------------------------------------------------------
# Devcontainer command variables
# ------------------------------------------------------------
# scripts/dc-run.sh is the single dispatcher: it detects in/out of the
# devcontainer (via IN_DEVCONTAINER / DC_RUN_REEXEC) and either runs the
# command directly or re-execs itself via `devcontainer exec`. Recipes use
# `$(DC_RUN) [-w <workdir>] -- cmd args...` instead of the old shell-in-shell
# `$(DOCKER_COMMAND_PREFIX) bash -lc "cd ... && ..."` pattern.
DC_RUN := $(REPO_ROOT_IN_HOST)/scripts/dc-run.sh


$(DEVCONTAINER_STAMP): $(DEVCONTAINER_FILES)
	@echo "=== Ensuring devcontainer is up to date ==="
	devcontainer up --remove-existing-container $(DEVCONTAINER_WORKSPACE_FLAGS)
	@touch "$@"


# ------------------------------------------------------------
# Ensure the devcontainer is available for building components
# ------------------------------------------------------------
.PHONY: builder-image
builder-image: $(BUILDER_IMAGE_DEPS)
ifeq ($(IN_DEVCONTAINER),1)
	@echo "=== Skipping devcontainer startup (running inside devcontainer) ==="
else
	@if ! devcontainer exec $(DEVCONTAINER_WORKSPACE_FLAGS) true >/dev/null 2>&1; then \
		echo "=== Devcontainer is not running, bringing it up ==="; \
		devcontainer up --remove-existing-container $(DEVCONTAINER_WORKSPACE_FLAGS); \
		touch "$(DEVCONTAINER_STAMP)"; \
	else \
		echo "=== Devcontainer already up to date ==="; \
	fi
endif
