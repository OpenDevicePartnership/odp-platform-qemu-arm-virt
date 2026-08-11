# ODP QEMU Platform

This book documents the Open Device Partnership reference platform for the
QEMU arm-virt platform. The repository assembles the platform firmware,
embedded controller firmware, secure services, UEFI, Windows image, and
end-to-end tests needed for development and validation.

## Quick start

Open the repository in its devcontainer, then build all firmware artifacts:

```console
make all
```

Boot the UEFI-only configuration:

```console
make run
```

Build and boot the Windows image:

```console
make run_os
```

Run the end-to-end test suite:

```console
make e2e-test
```

See the [repository README](https://github.com/OpenDevicePartnership/odp-platform-qemu-arm-virt)
for project status and contribution information.
