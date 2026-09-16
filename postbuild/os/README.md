# Booting Validation OS Image

## Preparing the Windows Validation OS (WinVOS) Image

WinVOS is a pared down Windows OS image that is convenient for basic development while also booting relatively quickly under QEMU.  

The image is built by the `build_os_image` GitHub Actions workflow (`.github/workflows/build-os.yml`), which injects the QEMU drivers listed in `prebuilt/driverlist.txt`. Pull requests build the image for validation only; pushes to `main` and manual runs publish `os-image.zip` as an asset on the rolling `latest` prerelease. The release image intentionally excludes repository ACPI content. Running `make run_os` or `make -C postbuild/os qcow2` downloads the base into `prebuilt/ValidationOS.vhdx`, compiles the current platform ACPI, and injects it into the local `build/winvos.qcow2` overlay. The download is anonymous, so no `gh auth login` is needed. To build manually, download the ISO from https://aka.ms/DownloadValidationOS_arm64.


## Booting QEMU `virt` to Windows

After you have created a ValidationOS.vhdx with your required files, simply copy it to the prebuilt folder and from the root folder run
    `make run_os`

This will generate the qcow2 image from the vhdx and run your BIOS in the parent folder path and boot to a command prompt. Your output display will be redirected to VNC port 5900 by default. You can use and VNC Viewer to open the display `127.0.0.1:5900`. 

If you want you can force regeneration of the winvos.qcow2 image using
    `make -C postbuild/os qcow2`

## Connecting with Windbg

GDB server is at:  `127.0.0.1:5555`. 

Windbg can be connected on  `windbg -k com:ipport=56789,port=127.0.0.1 -v`

## Windows ACPI end-to-end tests

From a fresh clone with `git`, `make`, the devcontainer CLI, and a usable
Docker daemon:

```sh
make windows-acpi-e2e
```

This default thermal test exercises Windows ACPI through FF-A and the secure
thermal service to the EC over MCTP-over-UART. Battery uses the same EC-sidecar
lifecycle:

```sh
make windows-acpi-e2e WINDOWS_ACPI_E2E_SERVICE=battery
```

It checks the deterministic battery-0 status through the existing
`\_SB.ECT0.TBST` to `\_SB.BAT0._BST` route: discharging-only `battery_state=1`,
present rate `1500` mA, remaining capacity `2304` mAh, and present voltage
`11850` mV. There is no battery selector, battery-1 coverage, or native Windows
battery enumeration.

To exercise the secure UCSI stub without an EC sidecar:

```sh
make windows-acpi-e2e WINDOWS_ACPI_E2E_SERVICE=ucsi
```

Only `thermal`, `ucsi`, and `battery` are accepted. The UCSI executable reads
connector 1 through the shared Windows ACPI `UcsiSource::get_snapshot` API and checks
UCSI version `0x0120`, one PD-capable connector with PD revision `0x0300`,
DRP/USB2/USB3/provider/consumer support, and a connected USB partner with sink
power direction. It does not test native Windows UCSI class-driver enumeration.

The target initializes submodules, provisions the devcontainer, downloads a
verified stable ValidationOS base, builds current firmware and ACPI, injects
the run payload into a disposable overlay, and shuts down Windows unattended.
Thermal and battery run declarative tests through the release
`ec-test-cli --source acpi script run` interface. UCSI builds this checkout's
locked ARM64 smoke executable with `cargo-xwin` and injects it into the overlay;
it does not depend on UCSI commands in the release CLI.
These are focused service selections with fixed payloads, success summaries,
and runtime evidence under one shared lifecycle, not a generic adapter API.
Battery reuses the CLI's existing structured ACPI decoding; it adds no decoder
or standalone smoke crate.
The stable base must be ValidationOS build 28000 or newer and include the
ectest KMDF driver plus the EC test applications under `C:\ectest`.
Battery additionally requires an `odp-platform-common` CLI release that exposes
numeric `battery_state` in `battery.get_bst`, and an image rebuilt with that
release. A CLI/image that omits this field cannot qualify: the state assertion
must fail, not be skipped or replaced by a locally built payload.
The producer uses Microsoft's public 26H1 ARM64 image at
`https://aka.ms/DownloadValidationOS_26H1_arm64`.

Before boot, the runner checks the generated
`mod/secure-services/Build/qemu-ec-sp.dts` from the current firmware build for
the selected service's UUID word tuple, partition ID `0x8002`, and direct
request/response capability. The guest thermal DSL result is the independent
runtime proof that Windows ACPI reaches and receives a response from that
configured thermal service through FF-A.
Battery requires all four DSL checks to pass, the current run's EC
`Starting uart service` boot marker, and a secure FF-A request trace containing
battery UUID `25cb5207-ac36-427d-aaef-3aa78877d27e`, not merely the static manifest.
UCSI also requires a current-run secure FF-A request trace containing
its UUID. Its exact required ARM64 driver inventory and UUID live under
`windows-acpi-e2e/adapters/ucsi/`; unrelated
drivers already installed in the shared base are allowed.
The pinned Hafnium emits this request trace through UART0 into `serial0.log`;
the separate UART1 `secure_mm.log` is not the battery or UCSI execution evidence.

The release asset is accepted only with the SHA-256 digest provided by GitHub.
Override `WINDOWS_ACPI_E2E_REPO` and `WINDOWS_ACPI_E2E_RELEASE` for validation
forks.
Before creating an overlay, the consumer inspects the verified base offline to
confirm its Windows build and `C:\ectest\ec-test-cli.exe`; successful checks
are cached by the verified release digest.
UCSI driver inventory checks also run when the base was previously validated
for thermal. The rolling release may change: evidence must refer to the actual
downloaded image digest and observed Windows build, not an older qualification.

Successful runs retain compact evidence under `.e2e/evidence/`, including the
verified generated manifest, guest result, and boot logs, and remove their overlay.
Failed runs also retain the full run directory.
Battery retains `battery.log` plus the host, secure serial, and EC-sidecar logs.
UCSI logs include `ucsi.log` and the smoke build evidence. A valid result needs
the complete service-specific summary, exact `PASS: Windows ACPI E2E` result,
zero QEMU exit status, and the corresponding runtime evidence.

Pull-request CI runs all three services against the VHDX produced by the
workflow's Windows build job. `WINDOWS_ACPI_E2E_BASE_IMAGE` selects that
repo-local artifact instead of downloading the rolling release; all build,
overlay, boot, verification, and evidence logic remains shared.

### Aggregate qualification

```sh
make windows-acpi-e2e-all
```

This initializes/provisions and enters the devcontainer once, then invokes the
existing runner in fixed **thermal, ucsi, battery** order, always continuing
after failures. It ignores the service selection for the matrix; individual
commands above and the CI matrix remain unchanged. Issue #148 is the shared
image/build/overlay/QEMU/evidence infrastructure, not a fourth runnable adapter.

Use the same `WINDOWS_ACPI_E2E_REPO` / `WINDOWS_ACPI_E2E_RELEASE` inputs, or
`WINDOWS_ACPI_E2E_BASE_IMAGE=path/to/prepared.vhdx` for an already prepared,
repo-local image. Without an explicit prepared image, the first service that
resolves and validates a base pins that exact local VHDX for later services,
even if that service subsequently fails. A service blocked before selecting a
base leaves the next service free to establish the pin; once pinned, the suite
does not resolve the rolling release again. It reads the runner's existing
`base-image.txt`, maps its host path back into the container, and accepts only
one absolute, regular, non-symlink `.vhdx` path inside the repository/cache.
Invalid or conflicting records, or missing records after a runnable
qualification, make the aggregate nonzero and leave remaining services
`BLOCKED` rather than risk qualifying different bases. Explicit prepared-image
inputs continue to be passed unchanged to every runner.

The immutable `.e2e/assets`, `.e2e/bases`, and `.e2e/validated` caches and normal
incremental Make/Cargo artifacts are reused; each service still gets a fresh
overlay and evidence. `WINDOWS_ACPI_E2E_CACHE_DIR` can select another
non-symlinked, repo-local cache (use a relative path across the container boundary).

The suite prints and persists `summary.tsv` under a unique
`.e2e/evidence/suite-<id>/` directory, with tab-separated columns:

```text
service	status	exit_code	evidence
```

Evidence paths are repository-relative. `PASS` means the individual runner
exited zero. `FAIL` means a nonzero exit with current `result.txt` or
`qemu-status.txt` evidence, including QEMU timeout/run failures without guest
results. `BLOCKED` means setup, build, or image compatibility prevented that
run evidence. The aggregate exits zero only when all three pass; it does not
reinterpret the runner's payload assertions.

Each row retains the runner's evidence at `.e2e/evidence/<run-id>/`, with
`host.log` copied from the independent `suite-<id>/<service>-host.log`, including
preflight failures. `source.txt` records the suite's commit/worktree status;
`image-input.txt` records the requested image input separately from the matrix.
For release-based suites, it also records `pinned-service`, the container-local
`pinned-base`, and the first selected base's `base-image.txt` contents, preserving
the original release digest even though later runners receive a local image.
Per-service `base-image.txt` and `image-validation.txt` still retain each run's
verified digest, image SHA-256, and observed Windows build.

Individual runs optionally accept `WINDOWS_ACPI_E2E_RUN_ID` containing only
ASCII letters, digits, underscores, and hyphens. Evidence is deterministically
located at `<cache>/evidence/<run-id>/`. Existing run or evidence paths,
including dangling symlinks and completed successful runs, are rejected;
evidence-directory creation atomically reserves the identity. An omitted or
empty ID keeps the timestamp/PID default. The suite generates its own short,
unique IDs, ignoring any inherited run ID.
