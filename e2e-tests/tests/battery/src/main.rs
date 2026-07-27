//! E2E test: Battery service GetBst via FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!

#![no_main]
#![no_std]

extern crate alloc;

use test_support::{run_tests, E2eContext, BATTERY_UUID};
use uefi::prelude::*;

/// EC Battery GetBst opcode (see battery-service-relay `BatteryCmd::GetBst = 2`).
const EC_BAT_GET_BST: u8 = 0x02;

// EC dev-qemu MockFuelGauge (3S, ~80% SoC, discharging) BST values, mapped by
// the EC's compute_bst. These are fixed mock constants, asserted exactly.
const EXPECT_STATE_DISCHARGING: u32 = 0x1; // ACPI BatteryState::DISCHARGING = 1<<0
const EXPECT_PRESENT_RATE: u32 = 1500; // |−1500 mA| discharge
const EXPECT_REMAINING_CAPACITY: u32 = 2304; // mAh
const EXPECT_PRESENT_VOLTAGE: u32 = 11850; // mV (3 × 3950)

#[entry]
fn main() -> Status {
    run_tests(test_battery_get_bst)
}

fn test_battery_get_bst(ctx: &mut E2eContext) {
    // NOTE: the SP Battery service currently ignores the request payload and
    // always relays GetBst for battery 0 (ec-service-lib battery.rs get_bst(0)).
    // So this proves the SP↔EC GetBst relay round-trip, not SP request-opcode
    // decoding; the [opcode, id] below documents intent but is not parsed by
    // the SP today.
    let battery_id: u8 = 0;
    let Some(resp_payload) = ctx.send_command(
        "battery_get_bst",
        &BATTERY_UUID,
        EC_BAT_GET_BST,
        &[battery_id],
    ) else {
        return;
    };

    // Response layout (4 LE u32): state@0, rate@4, capacity@8, voltage@12.
    let state = resp_payload.u32_at(0);
    let rate = resp_payload.u32_at(4);
    let capacity = resp_payload.u32_at(8);
    let voltage = resp_payload.u32_at(12);

    log::info!(
        "  GetBst: state={:#x} rate={} capacity={} voltage={}",
        state,
        rate,
        capacity,
        voltage,
    );

    // Exact equality: the mock is discharging only (DISCHARGING set, CHARGING /
    // CRITICAL / CHARGE_LIMITING clear), so the ACPI state word is exactly 0x1.
    if state != EXPECT_STATE_DISCHARGING {
        ctx.fail("battery_get_bst", "EC BST state != DISCHARGING-only (0x1)");
        return;
    }
    if rate != EXPECT_PRESENT_RATE {
        ctx.fail("battery_get_bst", "present_rate != EC mock value");
        return;
    }
    if capacity != EXPECT_REMAINING_CAPACITY {
        ctx.fail("battery_get_bst", "remaining_capacity != EC mock value");
        return;
    }
    if voltage != EXPECT_PRESENT_VOLTAGE {
        ctx.fail("battery_get_bst", "present_voltage != EC mock value");
        return;
    }
    ctx.pass("battery_get_bst");
}
