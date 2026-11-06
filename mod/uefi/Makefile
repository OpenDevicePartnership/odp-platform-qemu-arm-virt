# UEFI firmware build targets for the ODP QEMU Platform.
#
# SPDX-License-Identifier: MIT
#


include ../../Common.mk

# QEMU display mode. `vnc` (the default) keeps the flow headless over VNC
# (port 5900, forwarded by the devcontainer); `gtk` renders in a native window
# (e.g. `make run_os QEMU_DISPLAY=gtk`); `none` disables display.
QEMU_DISPLAY ?= vnc
ODP_E2E_QEMU_PID_FILE ?=
ODP_E2E_EC_PTY ?=

# serial0 must never be a pipe. QEMU's PL011 TX calls qemu_chr_fe_write_all(),
# which retries under the BQL when the backend stops draining and freezes the
# whole VM; a regular file never blocks. The `run` target tails this log into
# the terminal. Set to empty to get the old `-serial stdio` behaviour back.
SERIAL0_LOG ?= $(REPO_ROOT_IN_DEVCONTAINER)/mod/uefi/patina-qemu/Build/serial0.log
ODP_E2E_SERIAL0_LOG ?= $(SERIAL0_LOG)

# QEMU wrapper that injects the EC co-simulation chardev sockets without
# patching the patina-qemu submodule's QemuRunner plugin. Passed to stuart as
# the QEMU_PATH build var; the real qemu binary is forwarded via REAL_QEMU.
QEMU_EC_WRAPPER_DC := $(REPO_ROOT_IN_DEVCONTAINER)/scripts/qemu-ec-wrapper.sh

QEMU_RUN_ENV = $(if $(ODP_E2E_QEMU_PID_FILE),ODP_E2E_QEMU_PID_FILE=$(ODP_E2E_QEMU_PID_FILE),)
QEMU_RUN_ENV += EC_I2C_SOCK="$(EC_I2C_SOCK)" EC_GPIO_SOCK="$(EC_GPIO_SOCK)" EC_UART_SOCK="$(EC_UART_SOCK)"
QEMU_RUN_ARGS = QEMU_PATH=$(QEMU_EC_WRAPPER_DC)
ifeq ($(ARCH),aarch64)
QEMU_RUN_ENV += $(if $(ODP_E2E_EC_PTY),ODP_E2E_EC_PTY=$(ODP_E2E_EC_PTY),) \
	$(if $(ODP_E2E_SERIAL0_LOG),ODP_E2E_SERIAL0_LOG=$(ODP_E2E_SERIAL0_LOG),)
QEMU_RUN_ARGS += SERIAL_PORT=56789
endif

all: $(if $(filter aarch64,$(ARCH)),patina-qemu-odp-sp,patina-qemu-odp)

patina-qemu-prepare: builder-image
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_setup -c $(UEFI_BUILD_CONFIG)
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_update -c $(UEFI_BUILD_CONFIG)

# ------------------------------------------------------------
# Build baseline Patina UEFI
# ------------------------------------------------------------
patina-qemu: patina-qemu-prepare
	$(call GROUP,Build baseline UEFI)
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_build -c $(UEFI_BUILD_CONFIG)
	$(call ENDGROUP)

# ------------------------------------------------------------
# Build UEFI with the ODP platform overlay
# ------------------------------------------------------------
patina-qemu-odp: patina-qemu-prepare
	$(call GROUP,Build UEFI with ODP overlay)
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_build -c $(UEFI_BUILD_CONFIG) \
		FEATURE_CONFIG_PATH=$(REPO_ROOT_IN_DEVCONTAINER)/mod/uefi/platform
	$(call ENDGROUP)

# ------------------------------------------------------------
# Build UEFI with the ODP overlay and ARM secure partition
# ------------------------------------------------------------
# REPO_ROOT_IN_DEVCONTAINER is referenced for stuart args (paths must be
# valid inside the container where stuart actually runs).
patina-qemu-odp-sp: patina-qemu-prepare
	$(call GROUP,Build UEFI with ODP overlay and ARM secure partition)
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_build -c $(UEFI_BUILD_CONFIG) \
		HAF_TFA_BUILD=TRUE \
		BLD_*_TPM2_ENABLE=TRUE \
		DISABLE_DEBUG_MACRO_CHECK=TRUE \
		MSSP_RUST_BIN_FILE=$(REPO_ROOT_IN_DEVCONTAINER)/mod/secure-services/Build/qemu-ec-sp.bin \
		MSSP_RUST_DTS_FILE=$(REPO_ROOT_IN_DEVCONTAINER)/mod/secure-services/Build/qemu-ec-sp.dts \
		FEATURE_CONFIG_PATH=$(REPO_ROOT_IN_DEVCONTAINER)/mod/uefi/platform
	$(call ENDGROUP)

builder-shell: builder-image
	@$(DC_RUN) --shell

run: builder-image
	@tail_pid=; \
	if [ "$(ARCH)" = aarch64 ] && [ -n "$(ODP_E2E_SERIAL0_LOG)" ]; then \
		mkdir -p $(dir $(ODP_E2E_SERIAL0_LOG)); \
		: > $(ODP_E2E_SERIAL0_LOG); \
		tail -f $(ODP_E2E_SERIAL0_LOG) & tail_pid=$$!; \
	fi; \
	trap 'if [ -n "$$tail_pid" ]; then kill $$tail_pid 2>/dev/null || true; fi' EXIT INT TERM; \
	$(DC_RUN) -w mod/uefi/patina-qemu -- \
		env REAL_QEMU=$(QEMU_PATH) QEMU_DISPLAY=$(QEMU_DISPLAY) $(QEMU_RUN_ENV) \
		stuart_build -c $(UEFI_BUILD_CONFIG) --flashonly GDB_SERVER=5555 PATH_TO_OS=$(PATH_TO_OS) $(QEMU_RUN_ARGS)

clean:
	@echo "=== Cleaning UEFI build artifacts ==="
	cd $(REPO_ROOT_IN_HOST)/mod/uefi/patina-qemu && rm -rf Build Conf

.PHONY : all builder-image builder-shell patina-qemu-prepare patina-qemu patina-qemu-odp patina-qemu-odp-sp run clean
