# QEMU Setup

This section covers how to setup QEMU and boot windows image. We use QEMU as a reference for developing features that are not yet fully supported in hardware. This also gives us a HW agnostic platform that any SV or OEM can use for development.

## Downloading and building QEMU

[QEMU Builder](https://github.com/openDevicePartnership/odp-qemu-builder) has patches and HW features such as an I2C controller that we've added to QEMU. The QEMU that is included in the docker image already picks up the latest QEMU from here. If you want to make further modifications to QEMU download the odp-qemu-builder and follow the instructions there.

## Running QEMU with Windows

The windows image generation is done by .github\workflows\build-os.yml. This downloads the latest version of Validation OS and injects drivers and ACPI content into the windows image. On pushes to `main` the image is zipped and published as the `os-image.zip` asset on the rolling `latest` prerelease; pull requests only build it for validation. Running "make run_os" will pull and unzip that asset.

If you want to create your own windows image you can modify the one downloaded at postbuild/os/prebuilt/ValidationOS.vhdx and place your updated image there.
