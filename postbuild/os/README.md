# Booting Validation OS Image

## Preparing the Windows Validation OS (WinVOS) Image

WinVOS is a pared down Windows OS image that is convenient for basic development while also booting relatively quickly under QEMU.  

The image is built by the `build_os_image` GitHub Actions workflow (`.github/workflows/build-os.yml`), which injects the QEMU drivers listed in `prebuilt/driverlist.txt`. Pull requests build the image for validation only; pushes to `main` and manual runs publish `os-image.zip` as an asset on the rolling `latest` prerelease. Running `make run_os` or `make qcow2` downloads and unzips that asset into `prebuilt/ValidationOS.vhdx`. The download is anonymous, so no `gh auth login` is needed. To build manually, download the ISO from https://aka.ms/DownloadValidationOS_arm64.


## Booting QEMU `virt` to Windows

After you have created a ValidationOS.vhdx with your required files, simply copy it to the prebuilt folder and from the root folder run
    `make run_os`

This will generate the qcow2 image from the vhdx and run your BIOS in the parent folder path and boot to a command prompt. Your output display will be redirected to VNC port 5900 by default. You can use and VNC Viewer to open the display `127.0.0.1:5900`. 

If you want you can force regeneration of the winvos.qcow2 image using
    `make qcow2`

## Connecting with Windbg

GDB server is at:  `127.0.0.1:5555`. 

Windbg can be connected on  `windbg -k com:ipport=56789,port=127.0.0.1 -v`

## Windows ACPI end-to-end test

From a fresh clone with `git`, `make`, the devcontainer CLI, and a usable
Docker daemon:

```sh
make windows-acpi-e2e
```

The target initializes submodules, provisions the devcontainer, downloads a
verified stable ValidationOS base, builds current firmware and ACPI, injects
the run payload into a disposable overlay, and runs a declarative thermal test
through the release `ec-test-cli --source acpi script run` interface.
The stable base must be ValidationOS build 28000 or newer and include the
ectest KMDF driver plus the EC test applications under `C:\ectest`.
The producer uses Microsoft's public 26H1 ARM64 image at
`https://aka.ms/DownloadValidationOS_26H1_arm64`.

Before boot, the runner checks the generated
`mod/secure-services/Build/qemu-ec-sp.dts` from the current firmware build for
the thermal UUID word tuple, partition ID `0x8002`, and direct
request/response capability. The guest thermal DSL result is the independent
runtime proof that Windows ACPI reaches and receives a response from that
configured thermal service through FF-A.

The release asset is accepted only with the SHA-256 digest provided by GitHub.
Override `WINDOWS_ACPI_E2E_REPO` and `WINDOWS_ACPI_E2E_RELEASE` for validation
forks.
Before creating an overlay, the consumer inspects the verified base offline to
confirm its Windows build and `C:\ectest\ec-test-cli.exe`; successful checks
are cached by the verified release digest.

Successful runs retain compact evidence under `.e2e/evidence/`, including the
verified generated manifest and guest thermal result, and remove their overlay.
Failed runs also retain the full run directory.

Pull-request CI runs this same Make target against the VHDX produced by the
workflow's Windows build job. `WINDOWS_ACPI_E2E_BASE_IMAGE` selects that
repo-local artifact instead of downloading the rolling release; all build,
overlay, boot, verification, and evidence logic remains shared.
