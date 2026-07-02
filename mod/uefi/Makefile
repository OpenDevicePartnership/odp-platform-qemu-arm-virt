# UEFI firmware build targets for the ODP QEMU ARM Virt Platform.
#
# SPDX-License-Identifier: MIT
#


include ../../Common.mk

# TPM is enabled for the QEMU ARM VIRT build by default. Callers can
# override TPM_DEV at invocation time, e.g. `make run TPM_DEV=/tmp/swtpm.sock`.
TPM_DEV ?= /tmp/mytpm1/swtpm-sock

# Unix sockets used to connect QEMU's virtual I2C controller and PL061 GPIO
# to an external embedded controller (EC) QEMU instance. The EC side creates
# the socket servers; this QEMU connects to them as a client (server=off).
# Set to empty to disable (e.g. `make run EC_I2C_SOCK= EC_GPIO_SOCK=`).
EC_I2C_SOCK ?= /tmp/qemu-ec-i2c.sock
EC_GPIO_SOCK ?= /tmp/qemu-ec-gpio.sock

# QEMU wrapper that injects the EC co-simulation chardev sockets without
# patching the patina-qemu submodule's QemuRunner plugin. Passed to stuart as
# the QEMU_PATH build var; the real qemu binary is forwarded via REAL_QEMU.
QEMU_EC_WRAPPER_DC := $(REPO_ROOT_IN_DEVCONTAINER)/scripts/qemu-ec-wrapper.sh

all: patina-qemu-ec

# ------------------------------------------------------------
# Build UEFI without EC Support
# ------------------------------------------------------------
patina-qemu: builder-image
	$(call GROUP,Build UEFI (no EC))
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_setup -c Platforms/QemuArmVirtPkg/PlatformBuild.py
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_update -c Platforms/QemuArmVirtPkg/PlatformBuild.py
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_build -c Platforms/QemuArmVirtPkg/PlatformBuild.py
	$(call ENDGROUP)

# ------------------------------------------------------------
# Build UEFI with EC Support
# ------------------------------------------------------------
# REPO_ROOT_IN_DEVCONTAINER is referenced for stuart args (paths must be
# valid inside the container where stuart actually runs).
patina-qemu-ec: builder-image
	$(call GROUP,Build UEFI with EC)
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_setup -c Platforms/QemuArmVirtPkg/PlatformBuild.py
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_update -c Platforms/QemuArmVirtPkg/PlatformBuild.py
	@$(DC_RUN) -w mod/uefi/patina-qemu -- stuart_build -c Platforms/QemuArmVirtPkg/PlatformBuild.py \
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
	@mkdir -p "$(dir $(TPM_DEV))"
	@REAL_QEMU=$(QEMU_PATH) EC_I2C_SOCK=$(EC_I2C_SOCK) EC_GPIO_SOCK=$(EC_GPIO_SOCK) \
		$(DC_RUN) -w mod/uefi/patina-qemu -- \
		stuart_build -c Platforms/QemuArmVirtPkg/PlatformBuild.py --flashonly GDB_SERVER=5555 SERIAL_PORT=56789 TPM_DEV=$(TPM_DEV) PATH_TO_OS=$(PATH_TO_OS) QEMU_PATH=$(QEMU_EC_WRAPPER_DC)

clean:
	@echo "=== Cleaning UEFI build artifacts ==="
	cd $(REPO_ROOT_IN_HOST)/mod/uefi/patina-qemu && rm -rf Build Conf

.PHONY : all builder-image builder-shell patina-qemu patina-qemu-ec run clean
