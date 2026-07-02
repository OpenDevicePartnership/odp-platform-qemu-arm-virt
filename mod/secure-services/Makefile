# Secure Services build targets for the ODP QEMU ARM Virt Platform.
#
# SPDX-License-Identifier: MIT
#

QEMU_RUST_BIN := Build/qemu-ec-sp.bin
QEMU_RUST_DTS := Build/qemu-ec-sp.dts
EC_SECURE_DTS := platform/linker/qemu-ec-sp.dts

include ../../Common.mk

# Optional cargo features (e.g. test-bypass-locality-check for e2e tests)
CARGO_FEATURES ?=
# Cargo profile to build with (release or coverage)
CARGO_PROFILE ?= release

all: $(QEMU_RUST_BIN) $(QEMU_RUST_DTS)

# ------------------------------------------------------------
# Build Secure EC Service
# ------------------------------------------------------------
$(QEMU_RUST_BIN): $(QEMU_RUST_DTS) builder-image
	$(call GROUP,Build Secure EC Service)
	@mkdir -p Build
	@$(DC_RUN) -w mod/secure-services/platform -- \
		cargo objcopy --target=aarch64-unknown-none --profile $(CARGO_PROFILE) $(if $(CARGO_FEATURES),--features=$(CARGO_FEATURES),) -- -O binary ../$(QEMU_RUST_BIN)
	$(call ENDGROUP)

# ------------------------------------------------------------
# Copy DTS file to build directory
# ------------------------------------------------------------
$(QEMU_RUST_DTS): $(EC_SECURE_DTS)
	mkdir -p Build
	cp $(EC_SECURE_DTS) $(QEMU_RUST_DTS)

clean:
	rm -rf Build
	@$(DC_RUN) -w mod/secure-services/platform -- cargo clean

.PHONY: all clean
