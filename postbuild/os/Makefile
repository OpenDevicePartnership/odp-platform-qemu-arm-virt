# OS image build targets for the ODP QEMU Platform.
#
# SPDX-License-Identifier: MIT
#

include ../../Common.mk

# ------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------
WORKSPACE ?= $(CURDIR)
OS_IMAGE_OUTPUT := build/$(ARCH)/winvos.qcow2
OS_IMAGE_INPUT := prebuilt/$(ARCH)/ValidationOS.vhdx
OS_IMAGE_RELEASE ?= latest
# Revisit: Will specifically name os-image-aarch64.zip in a later change which will allow this to be removed
OS_IMAGE_ASSET ?= $(if $(filter aarch64,$(ARCH)),os-image.zip,os-image-$(ARCH).zip)
OS_IMAGE_ASSET_FILE ?= os-image.vhdx
OS_IMAGE_REPO ?= OpenDevicePartnership/odp-platform-qemu-arm-virt

ACPI_TABLES_DIR := ../../mod/uefi/platform/$(UEFI_PACKAGE)/AcpiTables
ACPI_TABLE_SOURCES := $(wildcard $(ACPI_TABLES_DIR)/*.asl \
	../../mod/uefi/platform/AcpiTables/*.asl)
ACPI_TABLE_OUTPUT := build/$(ARCH)/acpi/ACPITABL.dat

BIOS_FLASH0 := ../../$(BIOS_FV_DIR)/SECURE_FLASH0.fd
BIOS_EFI    := ../../$(BIOS_FV_DIR)/QEMU_EFI.fd
BIOS_OUTPUTS := $(BIOS_FLASH0) $(BIOS_EFI)

# ------------------------------------------------------------
# Throw error if the BIOS images are not present
# ------------------------------------------------------------
$(BIOS_OUTPUTS):
	@echo "Please build the BIOS images by running 'make all' in the root directory before building the OS image."
	@exit 1

# ------------------------------------------------------------
# Download the input image from the latest GitHub release if needed
# ------------------------------------------------------------
$(OS_IMAGE_INPUT):
	@set -eu; \
	url="https://github.com/$(OS_IMAGE_REPO)/releases/download/$(OS_IMAGE_RELEASE)/$(OS_IMAGE_ASSET)"; \
	mkdir -p prebuilt/$(ARCH); \
	rm -f prebuilt/$(ARCH)/$(OS_IMAGE_ASSET) prebuilt/$(ARCH)/$(OS_IMAGE_ASSET_FILE) "$(OS_IMAGE_INPUT)"; \
	echo "Downloading $$url"; \
	curl -fsSL --retry 3 -o prebuilt/$(ARCH)/$(OS_IMAGE_ASSET) "$$url"; \
	unzip -oq prebuilt/$(ARCH)/$(OS_IMAGE_ASSET) -d prebuilt/$(ARCH); \
	rm -f prebuilt/$(ARCH)/$(OS_IMAGE_ASSET); \
	if [ ! -f prebuilt/$(ARCH)/$(OS_IMAGE_ASSET_FILE) ]; then \
		echo "$(OS_IMAGE_ASSET) did not contain $(OS_IMAGE_ASSET_FILE)."; \
		exit 1; \
	fi; \
	mv prebuilt/$(ARCH)/$(OS_IMAGE_ASSET_FILE) "$(OS_IMAGE_INPUT)"; \
	echo "Downloaded $(OS_IMAGE_INPUT)."

# ------------------------------------------------------------
# Generate qcow2 overlay with current platform ACPI
# ------------------------------------------------------------
$(ACPI_TABLE_OUTPUT): $(ACPI_TABLE_SOURCES)
	mkdir -p $(dir $@)
	iasl -tc -p $(dir $@)ec -I $(ACPI_TABLES_DIR) $(ACPI_TABLES_DIR)/ec.asl
	cp $(dir $@)ec.aml $@

$(OS_IMAGE_OUTPUT): $(ACPI_TABLE_OUTPUT)

$(OS_IMAGE_OUTPUT): $(OS_IMAGE_INPUT)
	@set -eu; \
	mkdir -p $(dir $@); \
	cd $(dir $@); \
	temporary="$(notdir $@).tmp"; \
	rm -f "$$temporary"; \
	trap 'rm -f "$$temporary"' EXIT; \
	qemu-img create -q -f qcow2 -F vhdx -b "../../$(OS_IMAGE_INPUT)" "$$temporary"; \
	guestfish -a "$$temporary" -i upload "$(abspath $(ACPI_TABLE_OUTPUT))" /Windows/System32/ACPITABL.dat; \
	mv "$$temporary" $(notdir $@); \
	trap - EXIT

qcow2: $(OS_IMAGE_OUTPUT)

# ------------------------------------------------------------
# Clean everything
# ------------------------------------------------------------
clean:
	@echo "=== Cleaning OS image build artifacts ==="
	rm -rf build

