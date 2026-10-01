// SPDX-License-Identifier: MIT

use core::ffi::c_void;
use uefi::{
    boot::{self, OpenProtocolAttributes, OpenProtocolParams, ScopedProtocol},
    proto::unsafe_protocol,
    Status,
};

type Handler = unsafe extern "efiapi" fn(usize, *mut c_void);
type SourceOperation = unsafe extern "efiapi" fn(*mut HardwareInterrupt, usize) -> Status;

// Public HardwareInterrupt2 ABI; Patina's private trailing fields are not ours.
#[repr(C)]
#[unsafe_protocol("32898322-2da1-474a-baaa-f3f7cf569470")]
pub struct HardwareInterrupt {
    pub register: unsafe extern "efiapi" fn(*mut Self, usize, Option<Handler>) -> Status,
    pub enable: SourceOperation,
    pub disable: SourceOperation,
    pub state: unsafe extern "efiapi" fn(*mut Self, usize, *mut bool) -> Status,
    pub eoi: SourceOperation,
    pub get_trigger: unsafe extern "efiapi" fn(*mut Self, usize, *mut u32) -> Status,
    pub set_trigger: unsafe extern "efiapi" fn(*mut Self, usize, u32) -> Status,
}

pub fn open() -> Result<ScopedProtocol<HardwareInterrupt>, &'static str> {
    let handle = boot::get_handle_for_protocol::<HardwareInterrupt>()
        .map_err(|_| "HardwareInterrupt2 protocol unavailable")?;
    // This shared firmware protocol stays installed throughout boot services.
    unsafe {
        boot::open_protocol(
            OpenProtocolParams {
                handle,
                agent: boot::image_handle(),
                controller: None,
            },
            OpenProtocolAttributes::GetProtocol,
        )
        .map_err(|_| "cannot open HardwareInterrupt2 protocol")
    }
}

pub fn check(status: Status, operation: &'static str) -> Result<(), &'static str> {
    if status == Status::SUCCESS {
        Ok(())
    } else {
        log::error!("{operation}: {status:?}");
        Err(operation)
    }
}
