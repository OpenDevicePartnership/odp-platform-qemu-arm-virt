# RTC ACPI fixture

Run `make windows-acpi-e2e WINDOWS_ACPI_E2E_SERVICE=rtc`. The runner compiles
the actual `rtc.asl` through `ec.asl` and exercises it with the existing
declarative test runner, Windows ACPI evaluation driver, SP, and EC sidecar.
No physical wake, power-source switching, or notification delivery is tested.
RTC is also included in `windows-acpi-e2e-all` and the CI service matrix.

The image's CLI predates timestamp Buffer literals and RTC status checking.
The RTC run therefore builds the CLI from `platform-common-rev.txt` and
replaces it only in the disposable guest overlay. The pin combines
https://github.com/dymk/odp-platform-common/pull/2 and
https://github.com/dymk/odp-platform-common/pull/3 for fork review; replace
the fork source and revision with the merged upstream commit before promotion.
The run preserves the CLI revision, binary hash, build log, and guest results.

Milliseconds 0 for whole seconds follows the explicitly accepted existing
decoder compatibility policy, not a resolution of ACPI's published 1..1000
range. The DSL rejects values above 999 before invoking the shared decoder.

The focused `status.asl` regression includes the actual platform methods
with an echoed transport response. Compile with `iasl -I
mod/uefi/platform/QemuArmVirtPkg/AcpiTables -p /tmp/rtc-status
postbuild/os/windows-acpi-e2e/adapters/rtc/status.asl`, then run
`acpiexec -dr -b "execute MAIN" /tmp/rtc-status.aml`. `MAIN` must return
Integer 0 without evaluation errors: all four setters must reject nonzero
SP status even when the FF-A framework status is zero.
