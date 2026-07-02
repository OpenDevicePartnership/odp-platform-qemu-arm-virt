# Dockerfile for building/testing the ODP QEMU ARM Virt Platform with GCC.
#
# SPDX-License-Identifier: MIT
#

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Versions
ARG NASM_VERSION=2.16.01
ARG CSPELL_VERSION=5.20.0
ARG MARKDOWNLINT_VERSION=0.32.2

# Visit this NuGet package version page to see the latest version available
# https://dev.azure.com/projectmu/acpica/_artifacts/feed/mu_iasl/NuGet/edk2-acpica-iasl/versions
ARG IASL_VERSION=20230628.0.1

# Set environment variable to avoid interaction.
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Work-around for azure pipelines adding the vsts_azpcontainer user, but not adding
# the .local/bin directory to the path which will be used by pip.
ENV PATH=$PATH:/home/vsts_azpcontainer/.local/bin

RUN apt-get update && \
    apt-get install --yes --no-install-recommends \
    software-properties-common \
    && \
    apt-get update && \
    apt-get install --yes --no-install-recommends \
    bison \
    ca-certificates \
    clang \
    curl \
    device-tree-compiler \
    dosfstools \
    mtools \
    flex \
    gh \
    git \
    gnupg \
    gnupg2 \
    lcov \
    libssl-dev \
    lld \
    llvm \
    jq \
    m4 \
    make \
    mono-complete \
    npm \
    sudo \
    unzip \
    uuid-dev \
    wget \
    python3 \
    python3-venv \
    python-is-python3 \
    g++ \
    gcc \
    gcc-aarch64-linux-gnu \
    qemu-utils \
    swtpm \
    swtpm-tools \
    && \
    rm -rf /var/lib/apt/lists/*

ENV IN_DEVCONTAINER=1

RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip && \
    chmod -R g+w,o+w /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# RUN npm install -g npm
RUN npm install -g \
    cspell@${CSPELL_VERSION} \
    markdownlint-cli@${MARKDOWNLINT_VERSION}

RUN wget -O - https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/nasm-${NASM_VERSION}.tar.gz | \
    tar xz && cd nasm-${NASM_VERSION} && \
    ./autogen.sh && ./configure && make -j $(nproc) && make install && \
    cd .. && rm -rf nasm-${NASM_VERSION}

RUN mkdir -p iasl_temp && cd iasl_temp && \
    wget -O iasl_${IASL_VERSION}.nupkg "https://pkgs.dev.azure.com/projectmu/acpica/_apis/packaging/feeds/mu_iasl/nuget/packages/edk2-acpica-iasl/versions/${IASL_VERSION}/content?api-version=6.0-preview.1" && \
    unzip iasl_${IASL_VERSION}.nupkg -d /iasl_pkg_contents && \
    cp /iasl_pkg_contents/edk2-acpica-iasl/Linux-x86/iasl /usr/bin/iasl && chmod +x /usr/bin/iasl && \
    cd .. && rm -rf iasl_temp

RUN if [ "$(arch)" = "x86_64" ]; then \
    wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" && \
    dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb && \
    apt-get update && apt-get install -y powershell && apt-get clean; \
    fi

#
# Rust support
#
ENV HOME="/home/vscode"
ENV PATH="$HOME/.cargo/bin:$PATH"

# Install Rust/Cargo and extras (rust-src, rust fmt, cargo-make, cargo-tarpaulin)
USER vscode
RUN RUST_VERSION=1.92.0 && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain ${RUST_VERSION} --profile minimal && \
    rustup component add clippy rustfmt rust-src && \
    rustup target add aarch64-unknown-none aarch64-unknown-uefi riscv32imac-unknown-none-elf && \
    rustup component add llvm-tools-preview && \
    cargo install cargo-binstall@1.17.7 --locked && \
    cargo binstall -y cargo-binutils && \
    cargo binstall -y cargo-make@0.37.24 && \
    cargo binstall -y cargo-tarpaulin@0.31.5 && \
    cargo binstall -y sccache@0.10.0 && \
    cargo binstall -y defmt-print@1.0.0
USER root

#
# sccache: wrap both rustc and the GCC cross-compiler
#
ENV RUSTC_WRAPPER="sccache"

# Create sccache-wrapped scripts for the aarch64 GCC cross-toolchain.
# The UEFI build system invokes these via $GCC5_AARCH64_PREFIX, so placing
# the wrappers earlier in $PATH makes it transparent.
# - Compilers (gcc, cc) go through sccache for caching.
# - Other tools (gcc-ar, objcopy, etc.) are passed through directly.
# Note: only gcc is installed (not g++), so we only wrap what exists.
RUN mkdir -p /usr/local/lib/sccache && \
    for tool in gcc cc; do \
    printf '#!/bin/sh\nexec sccache /usr/bin/aarch64-linux-gnu-%s "$@"\n' "$tool" \
    > /usr/local/lib/sccache/aarch64-linux-gnu-$tool && \
    chmod +x /usr/local/lib/sccache/aarch64-linux-gnu-$tool; \
    done && \
    for tool in gcc-ar gcc-nm gcc-ranlib objcopy objdump ld as strip readelf ar ranlib nm; do \
    ln -sf /usr/bin/aarch64-linux-gnu-$tool /usr/local/lib/sccache/aarch64-linux-gnu-$tool 2>/dev/null || true; \
    done
ENV GCC5_AARCH64_PREFIX=/usr/local/lib/sccache/aarch64-linux-gnu-
ENV PATH="/usr/local/lib/sccache:$PATH"

# Install stuart tools for building UEFI
USER vscode
COPY mod/uefi/patina-qemu/pip-requirements.txt /tmp/pip-requirements.txt
RUN pip install --upgrade -r /tmp/pip-requirements.txt pip lcov_cobertura
USER root

COPY --from=ghcr.io/opendevicepartnership/odp-qemu-builder/qemu@sha256:91343c9470940727e607aa3c9515eeb58f2c4c39daf94c96aac8dee7052e61d3 /usr/local/bin/qemu-system-aarch64 /usr/local/bin/qemu-system-aarch64
COPY --from=ghcr.io/opendevicepartnership/odp-qemu-builder/qemu@sha256:91343c9470940727e607aa3c9515eeb58f2c4c39daf94c96aac8dee7052e61d3 /usr/local/bin/qemu-system-riscv32 /usr/local/bin/qemu-system-riscv32
COPY --from=ghcr.io/opendevicepartnership/odp-qemu-builder/qemu@sha256:91343c9470940727e607aa3c9515eeb58f2c4c39daf94c96aac8dee7052e61d3 /usr/local/share/qemu/ /usr/local/share/qemu/

USER vscode
