# Build/clean for everything under mod/
#
# SPDX-License-Identifier: MIT
#
# Keeps mod-specific impl details (EC cargo build, secure-services flavors,
# double UEFI invocation) out of the top-level Makefile. Top-level delegates
# with `make -C mod <target>`.

include ../Common.mk

# ------------------------------------------------------------
# Default target
# ------------------------------------------------------------
all: secure-services ec uefi

# ------------------------------------------------------------
# Secure Services
# ------------------------------------------------------------
secure-services:
	$(MAKE) -C secure-services all

# Build secure services with test features and coverage profile (for e2e tests).
secure-services-test:
	$(MAKE) -C secure-services all CARGO_FEATURES=test-bypass-locality-check CARGO_PROFILE=coverage

# ------------------------------------------------------------
# UEFI (depends on secure-services to consume its artifacts)
# ------------------------------------------------------------
uefi: secure-services uefi-only

# UEFI without rebuilding secure-services — used by e2e-test, which builds
# secure-services-test first and would have it clobbered by the regular dep.
uefi-only:
	$(MAKE) -C uefi patina-qemu-ec

# ------------------------------------------------------------
# EC firmware (RISC-V)
# ------------------------------------------------------------
# Paths are relative to mod/ (this Makefile's CWD when invoked with `-C mod`).
# Note: Common.mk defines EC_BINARY relative to the repo root for top-level
# consumers (e2e-test). We use a separate local-relative variable here
# so make's dependency tracking resolves correctly under -C mod.
EC_BUILD_DIR := ec/platform/dev-qemu
EC_BINARY_LOCAL := $(EC_BUILD_DIR)/target/riscv32imac-unknown-none-elf/release/dev-qemu
# `mod/ec` is a submodule, so its file list isn't valid until `submodule update --init`
# has run. Gate the binary rule on the submodule's manifest, and only enumerate sources
# once the manifest exists, so a deinit'd-then-reinit'd submodule properly invalidates
# the artifact.
EC_SUBMODULE_MANIFEST := ec/rust-toolchain.toml
EC_SOURCES := $(if $(wildcard $(EC_SUBMODULE_MANIFEST)),$(shell find ec -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' -o -name 'build.rs' -o -name 'memory.x' \)))

# Phony alias — lets callers say `make ec` while the real rule is on the artifact.
ec: $(EC_BINARY_LOCAL)

$(EC_SUBMODULE_MANIFEST):
	@echo "=== Initializing mod/ec submodule ==="
	cd $(REPO_ROOT_IN_HOST) && git submodule update --init --recursive -- mod/ec

# Track the submodule's checked-out SHA via .git/modules/.../HEAD so a `git submodule
# update` to a new commit (which doesn't necessarily change any file under mod/ec at
# parse time) still invalidates the binary.
$(EC_BINARY_LOCAL): $(EC_SUBMODULE_MANIFEST) $(EC_SOURCES) ../.git/modules/odp-embedded-controller/HEAD | builder-image
	$(call GROUP,Build EC firmware)
	@$(DC_RUN) -w mod/$(EC_BUILD_DIR) -- cargo build --release --locked
	$(call ENDGROUP)
	@touch $@

# Build (if stale) and launch the EC firmware in QEMU, interactively with defmt
# log decoding. Reuses the platform's qemu-ec.sh launcher, forcing it to use the
# devcontainer's bundled qemu-system-riscv32 (via the QEMU env var) so it never
# attempts a docker pull. The `env` prefix is how we thread QEMU through dc-run.sh,
# which only forwards a fixed set of --remote-env vars. qemu-ec.sh serves the
# /tmp/qemu-ec-{i2c,gpio}.sock sockets that `make run_os` connects to for EC
# co-simulation. Runs in the foreground; Ctrl-C to stop.
run_ec: $(EC_BINARY_LOCAL) | builder-image
	@$(DC_RUN) -w mod/$(EC_BUILD_DIR) -- \
		env QEMU=/usr/local/bin/qemu-system-riscv32 \
		./qemu-ec.sh target/riscv32imac-unknown-none-elf/release/dev-qemu

# ------------------------------------------------------------
# Clean
# ------------------------------------------------------------
clean: ec-clean
	$(MAKE) -C secure-services clean
	$(MAKE) -C uefi clean

# `mod/ec` has no Makefile of its own, so clean its cargo target dir
# from here. Skip silently if the submodule isn't initialized.
ec-clean:
	@if [ -f $(EC_SUBMODULE_MANIFEST) ]; then \
		$(DC_RUN) -w mod/$(EC_BUILD_DIR) -- cargo clean; \
	fi

.PHONY: all secure-services secure-services-test uefi uefi-only ec run_ec clean ec-clean
