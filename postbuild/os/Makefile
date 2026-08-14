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
OS_IMAGE_RELEASE ?= latest
OS_IMAGE_ASSET ?= os-image.zip
OS_IMAGE_ASSET_FILE ?= os-image.vhdx
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
# Download the input image from the latest GitHub release if needed
# ------------------------------------------------------------
$(OS_IMAGE_INPUT):
	@set -eu; \
	url="https://github.com/$(OS_IMAGE_REPO)/releases/download/$(OS_IMAGE_RELEASE)/$(OS_IMAGE_ASSET)"; \
	mkdir -p prebuilt; \
	rm -f prebuilt/$(OS_IMAGE_ASSET) prebuilt/$(OS_IMAGE_ASSET_FILE) "$(OS_IMAGE_INPUT)"; \
	echo "Downloading $$url"; \
	if ! curl -fsSL --retry 3 -o prebuilt/$(OS_IMAGE_ASSET) "$$url"; then \
		echo "Anonymous download failed; retrying with the GitHub CLI."; \
		if ! command -v gh >/dev/null 2>&1; then \
			echo "GitHub CLI (gh) is required to fetch $(OS_IMAGE_ASSET) from a non-public repo."; \
			exit 1; \
		fi; \
		if ! gh auth status >/dev/null 2>&1; then \
			echo "GitHub CLI is not authenticated. Run 'gh auth login' and retry."; \
			exit 1; \
		fi; \
		GH_FORCE_TTY=0 gh release download $(OS_IMAGE_RELEASE) --repo "$(OS_IMAGE_REPO)" --pattern "$(OS_IMAGE_ASSET)" --dir prebuilt --clobber; \
	fi; \
	unzip -oq prebuilt/$(OS_IMAGE_ASSET) -d prebuilt; \
	rm -f prebuilt/$(OS_IMAGE_ASSET); \
	if [ ! -f prebuilt/$(OS_IMAGE_ASSET_FILE) ]; then \
		echo "$(OS_IMAGE_ASSET) did not contain $(OS_IMAGE_ASSET_FILE)."; \
		exit 1; \
	fi; \
	mv prebuilt/$(OS_IMAGE_ASSET_FILE) "$(OS_IMAGE_INPUT)"; \
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

