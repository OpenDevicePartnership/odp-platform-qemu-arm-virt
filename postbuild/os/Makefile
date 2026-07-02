# OS image build targets for the ODP QEMU `virt` Platform.
#
# SPDX-License-Identifier: MIT
#

include ../../Common.mk

# ------------------------------------------------------------
# Workspace setup
# ------------------------------------------------------------
WORKSPACE ?= $(CURDIR)
OS_IMAGE_OUTPUT := build/winvos.qcow2
OS_IMAGE_INPUT := prebuilt/ValidationOS.vhdx
OS_IMAGE_ARTIFACT ?= os-image
OS_IMAGE_ARTIFACT_FILE ?= os-image.vhdx
OS_IMAGE_REPO ?= OpenDevicePartnership/odp-platform-qemu-arm-virt

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
# Download the input image from GitHub Actions if needed
# ------------------------------------------------------------
$(OS_IMAGE_INPUT):
	@set -eu; \
	if ! command -v gh >/dev/null 2>&1; then \
		echo "GitHub CLI (gh) is required to fetch $(OS_IMAGE_INPUT)."; \
		exit 1; \
	fi; \
	if ! gh auth status >/dev/null 2>&1; then \
		echo "GitHub CLI is not authenticated. Run 'gh auth login' and retry."; \
		exit 1; \
	fi; \
	repo="$(OS_IMAGE_REPO)"; \
	mkdir -p prebuilt; \
	rm -f prebuilt/$(OS_IMAGE_ARTIFACT_FILE) "$(OS_IMAGE_INPUT)"; \
	GH_FORCE_TTY=0 gh run download --repo "$$repo" --name "$(OS_IMAGE_ARTIFACT)" --dir prebuilt; \
	if [ ! -f prebuilt/$(OS_IMAGE_ARTIFACT_FILE) ]; then \
		echo "Artifact file not found prebuilt/$(OS_IMAGE_ARTIFACT_FILE) please manually run the workflow."; \
		exit 1; \
	fi; \
	mv prebuilt/$(OS_IMAGE_ARTIFACT_FILE) "$(OS_IMAGE_INPUT)"; \
	echo "Downloaded $(OS_IMAGE_INPUT)."

# ------------------------------------------------------------
# Generate qcow2 image from VHDX image
# ------------------------------------------------------------
$(OS_IMAGE_OUTPUT): $(OS_IMAGE_INPUT)
	mkdir -p build
	qemu-img convert -f vhdx -O qcow2 $< $(OS_IMAGE_OUTPUT)

qcow2: $(OS_IMAGE_OUTPUT)

# ------------------------------------------------------------
# Clean everything
# ------------------------------------------------------------
clean:
	@echo "=== Cleaning OS image build artifacts ==="
	rm -rf build

