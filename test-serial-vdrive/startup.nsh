# UEFI shell startup script for the serial-link smoke test.
#
# SPDX-License-Identifier: MIT
#

@echo -off
echo test-serial: ARM Virt reached UEFI shell, requesting shutdown
reset -s
