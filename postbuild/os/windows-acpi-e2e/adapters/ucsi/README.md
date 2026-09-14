# UCSI Windows ACPI smoke

Run from the repository root with a qualified ARM64 Windows ValidationOS image
(build 28000 or newer):

```sh
make windows-acpi-e2e WINDOWS_ACPI_E2E_SERVICE=ucsi
```

`drivers.txt` lists the three required ARM64 driver packages; other preinstalled
drivers are allowed. `secure-uuid.txt` identifies the secure UCSI service. The
shared runner validates these prerequisites, builds and injects the current
`smoke.exe`, and runs without an EC sidecar.

The smoke uses `ec-test-lib`'s shared `Acpi::new(0).get_snapshot(1)` path through
`ectest.sys` and `ECT0.USND`. One snapshot performs three FF-A requests, with
VERSION and GET_CAPABILITY sharing a response. Four typed assertion groups check:

- VERSION `0x0120`.
- One connector, USB Power Delivery support, and BCD PD revision `0x0300`.
- Connector 1 DRP, USB2, USB3, provider, and consumer support.
- A connected USB partner with sink power direction.

Only complete success prints `UCSI SUMMARY: 4 passed, 0 failed`. Acquisition or
assertion failures produce diagnostics and a nonzero exit. The shared `run.cmd`
captures `ucsi.log`, writes `result.txt`, and shuts down; the smoke owns none of
that lifecycle. See [Windows image and runner documentation](../../../README.md)
for image selection, runtime secure-routing evidence, and retained failure logs.

## Crate checks

The standalone crate uses Rust 1.92.0 and a public upstream `ec-test-lib` pin.
Its Cargo-generated lockfile retains the compatible `embedded-services` revision
from that library's own lockfile; update the dependency set together rather than
resolving a newer `embedded-services` branch tip independently.

Linux tests require `pkg-config` and `libudev-dev` for the library's serial
dependency. They validate shared mock snapshots and reject each required field
or flag mutation, but do not replace actual Windows execution.

```sh
cd postbuild/os/windows-acpi-e2e/adapters/ucsi/smoke
cargo fmt -- --check
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
```

From the same smoke crate directory, build the ARM64 Windows executable inside
the configured devcontainer, which provides `cargo-xwin` 0.23.0 and the Windows
target:

```sh
cargo xwin build --locked --release --target aarch64-pc-windows-msvc
```

The output is `target/aarch64-pc-windows-msvc/release/smoke.exe`.

The crate's `.cargo/config.toml` sets `target-feature=+crt-static` so the executable
does not require `VCRUNTIME140.dll`, which is absent from ValidationOS. Cargo
discovers this configuration from its working directory; passing only
`--manifest-path` from the repository root does not load it. Run ARM64 builds
from the smoke crate directory and inspect the result with
`llvm-readobj --coff-imports`: it must not import `VCRUNTIME140.dll`.
