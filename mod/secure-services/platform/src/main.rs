//! QEMU EC Secure Partition Service entry point.
//!
//! SPDX-License-Identifier: MIT
//!

#![cfg_attr(target_os = "none", no_std)]
#![cfg_attr(target_os = "none", no_main)]
#![deny(clippy::undocumented_unsafe_blocks)]
#![deny(unsafe_op_in_unsafe_fn)]

#[cfg(target_os = "none")]
mod baremetal;

#[cfg(not(target_os = "none"))]
fn main() {
    println!("qemu-sp stub");
}

/// TPM CRB MMIO base address.
///
/// Must match the device-region mapping in the SP manifest (`qemu-ec-sp.dts`).
#[cfg(target_os = "none")]
const TPM_CRB_MMIO_BASE: u64 = 0x40200000;
#[cfg(target_os = "none")]
const TPM_CRB_TPM_BASE: u64 = 0x0C000000;

#[cfg(target_os = "none")]
fn main() -> ! {
    use core::cell::RefCell;
    use ec_service_lib::services::{
        Battery, EcRelay, MctpSerialTransport, Thermal, TimeAlarm, Ucsi,
    };
    use ec_service_lib::MessageHandler;
    use odp_ffa::Function;

    log::info!("QEMU Secure Partition - build time: {}", env!("BUILD_TIME"));

    let version = odp_ffa::Version::new().exec().unwrap();
    log::info!("FFA version: {}.{}", version.major(), version.minor());

    let tpm_sst = ec_service_lib::services::TpmSst::new(TPM_CRB_TPM_BASE);
    let mut tpm = ec_service_lib::services::TpmService::new(tpm_sst, TPM_CRB_MMIO_BASE);

    // SAFETY: TPM_CRB_MMIO_BASE is mapped as a device region in the SP manifest (qemu-ec-sp.dts).
    unsafe {
        tpm.init();
    }

    // Shared EC relay over the secure PL011 (`ec_uart` device-region @ 0x09040000).
    // SAFETY: 0x09040000 is the secure PL011 MMIO region exposed to this SP by the
    // SPMC, declared as the `ec_uart` device-region in the SP DTS.
    let pl011 = unsafe { qemu_sp_uart::Pl011Uart::new(0x09040000) };
    let relay = RefCell::new(EcRelay::new(MctpSerialTransport::new(pl011)));

    MessageHandler::new()
        .append(Thermal::new(&relay))
        .append(Battery::new(&relay))
        .append(TimeAlarm::new(&relay))
        .append(ec_service_lib::services::FwMgmt::new())
        .append(ec_service_lib::services::Notify::new())
        .append(Ucsi::new())
        .append(tpm)
        .run_message_loop()
        .expect("Error in run_message_loop");

    unreachable!()
}
