# QEMU Setup

This section covers how to setup QEMU (for the host and EC) and boot the windows image. We use QEMU as a reference for developing features that are not yet fully supported in hardware. This also gives us a HW agnostic platform that any SV or OEM can use for development.

## Downloading and building QEMU

[QEMU Builder](https://github.com/openDevicePartnership/odp-qemu-builder) has patches and HW features such as an I2C controller that we've added to QEMU. The QEMU that is included in the docker image already picks up the latest QEMU from here. If you want to make further modifications to QEMU download the odp-qemu-builder and follow the instructions there.

## Running QEMU with Windows

The windows image generation is done by `.github/workflows/build-os.yml`. This downloads the latest version of Validation OS and injects the required drivers into a reusable base image. On pushes to `main` the image is zipped and published as the `os-image.zip` asset on the rolling `latest` prerelease; pull requests only build it for validation. Running `make run_os` downloads that ACPI-free base, compiles the current platform ACPI, injects it into a local qcow2 overlay, and boots the overlay.

If you want to create your own windows image you can modify the one downloaded at postbuild/os/prebuilt/ValidationOS.vhdx and place your updated image there.

## Connecting Windows to the virtual EC

The EC binary is built from the `dev-qemu` platform in the [odp-embedded-controller](https://github.com/OpenDevicePartnership/odp-embedded-controller) repo (pulled in here as a submodule).
This is a minimum platform that runs the ODP services using a mock temperature sensor, fan, battery, and real-time clock, along with a HAL written for the RISC-V QEMU `ec` platform to communicate over the virtual UART and I2C buses with the host. This platform can be modified locally during development.

Build and run the virtual EC with `make run_ec`. However, the EC running on its own won't do much.
To then connect the host, run `make run_os` as mentioned above (in a separate terminal window).
The EC QEMU instance creates the sockets and the host connects to them, but the order you run these in
does not matter since the host will attempt to reconnect periodically to the EC if it's not available.

If using VS Code, you can also run either the `run_os_ec` task (for the default headless host) or `run_os_ec_windowed` (for a GTK window).

From within Windows running on the host QEMU instance, you can verify the connection is successful by following these steps:

- Run `cd C:\ectest`
- Run `ec-test-tui.exe --source acpi`
- Verify all tabs show green (successful) status, indicating the host is sending commands to the EC and receiving data.
