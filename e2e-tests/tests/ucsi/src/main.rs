//! E2E test: UCSI PPM stub routing over FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!
//! Direct FF-A routing smoke: drives the three read commands the secure-world
//! UCSI stub answers and asserts VERSION/CCI/MESSAGE-IN bytes. This proves
//! manifest advertisement, UUID routing, and the SP response — it does not
//! exercise the ACPI `ECT0.USND` path.

#![no_main]
#![no_std]

use test_support::{run_tests, E2eContext, UCSI_UUID};
use uefi::prelude::*;

/// FF-A payload byte 0: the doorbell tag the OS writes ahead of the mailbox.
const DOORBELL: u8 = 0x00;
/// Connector number the stub models (single-connector fixture).
const CONNECTOR_ONE: u8 = 1;

/// Mailbox offsets inside the response payload (48-byte UCSI mailbox at
/// payload offset 0).
const VERSION_OFFSET: usize = 0;
const CCI_OFFSET: usize = 4;
const CONTROL_OFFSET: usize = 8;
const MESSAGE_IN_OFFSET: usize = 16;

const OP_GET_CAPABILITY: u8 = 0x06;
const OP_GET_CONNECTOR_CAPABILITY: u8 = 0x07;
const OP_GET_CONNECTOR_STATUS: u8 = 0x12;

const VERSION_UCSI_1_2: u16 = 0x0120;

/// One UCSI read command and the exact response the stub must return.
struct Command {
    name: &'static str,
    opcode: u8,
    connector: u8,
    cci: u32,
    message_in: &'static [u8],
}

/// The three read commands the stub answers, each pinned to its opcode,
/// connector argument, expected CCI, and exact MESSAGE IN fixture.
const COMMANDS: &[Command] = &[
    Command {
        name: "ucsi_get_capability",
        opcode: OP_GET_CAPABILITY,
        connector: 0,
        cci: 0x8000_1000,
        message_in: &[
            0x46, 0x40, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x01, 0x00, 0x03,
            0x00, 0x02,
        ],
    },
    Command {
        name: "ucsi_get_connector_capability",
        opcode: OP_GET_CONNECTOR_CAPABILITY,
        connector: CONNECTOR_ONE,
        cci: 0x8000_0200,
        message_in: &[0x64, 0x03],
    },
    Command {
        name: "ucsi_get_connector_status",
        opcode: OP_GET_CONNECTOR_STATUS,
        connector: CONNECTOR_ONE,
        cci: 0x8000_0B00,
        message_in: &[
            0x00, 0x00, 0x29, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ],
    },
];

#[entry]
fn main() -> Status {
    run_tests(|ctx| {
        test_ucsi_partition_discovery(ctx);
        for cmd in COMMANDS {
            run_command(ctx, cmd);
        }
    })
}

fn test_ucsi_partition_discovery(ctx: &mut E2eContext) {
    const NAME: &str = "ucsi_partition_discovery";
    match ffa::ffa_partition_info_get_regs(&UCSI_UUID) {
        Ok((count, _)) if count > 0 => ctx.pass(NAME),
        Ok(_) => ctx.fail(NAME, "UCSI UUID is not advertised by any partition"),
        Err(_) => ctx.fail(NAME, "PARTITION_INFO_GET_REGS failed for UCSI UUID"),
    }
}

/// Send `[DOORBELL] + 48-byte mailbox` (opcode at CONTROL offset 0, connector
/// at CONTROL offset 2), then assert VERSION, CCI, and the exact MESSAGE IN.
fn run_command(ctx: &mut E2eContext, cmd: &Command) {
    let mut mailbox = [0u8; 48];
    mailbox[CONTROL_OFFSET] = cmd.opcode;
    mailbox[CONTROL_OFFSET + 2] = cmd.connector;

    let Some(m) = ctx.send_command(cmd.name, &UCSI_UUID, DOORBELL, &mailbox) else {
        return;
    };

    let version = m.u16_at(VERSION_OFFSET);
    let cci = m.u32_at(CCI_OFFSET);
    log::info!("  {}: version={version:#06x} cci={cci:#010x}", cmd.name);
    if version != VERSION_UCSI_1_2 {
        ctx.fail(cmd.name, "VERSION mismatch");
        return;
    }
    if cci != cmd.cci {
        ctx.fail(cmd.name, "CCI mismatch");
        return;
    }

    let got = m.slice(MESSAGE_IN_OFFSET..MESSAGE_IN_OFFSET + cmd.message_in.len());
    if got == cmd.message_in {
        ctx.pass(cmd.name);
    } else {
        log::error!(
            "  {}: MESSAGE IN mismatch got={got:02x?} expected={:02x?}",
            cmd.name,
            cmd.message_in
        );
        ctx.fail(cmd.name, "MESSAGE IN mismatch");
    }
}
