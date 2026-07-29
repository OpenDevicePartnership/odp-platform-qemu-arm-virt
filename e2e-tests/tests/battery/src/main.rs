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

// EC dev-qemu MockFuelGauge BST values, mapped by the EC's compute_bst. These
// are fixed mock constants, asserted exactly. State, rate and capacity are the
// same across both fuel-gauge profiles; only the pack voltage differs.
const EXPECT_STATE_DISCHARGING: u32 = 0x1; // ACPI BatteryState::DISCHARGING = 1<<0
const EXPECT_PRESENT_RATE: u32 = 1500; // |−1500 mA| discharge
const EXPECT_REMAINING_CAPACITY: u32 = 2304; // mAh
const EXPECT_VOLTAGE_3S: u32 = 11850; // mV (3 × 3950), battery 0
const EXPECT_VOLTAGE_2S: u32 = 7900; // mV (2 × 3950), battery 1

#[entry]
fn main() -> Status {
    run_tests(test_battery_get_bst)
}

fn test_battery_get_bst(ctx: &mut E2eContext) {
    // Battery 0 is the 3S pack; battery 1 the 2S pack. Both share state/rate/
    // capacity and differ only in pack voltage, so the id must select the pack.
    check_battery_bst(ctx, "battery0_get_bst", 0, EXPECT_VOLTAGE_3S);
    check_battery_bst(ctx, "battery1_get_bst", 1, EXPECT_VOLTAGE_2S);
}

fn check_battery_bst(ctx: &mut E2eContext, name: &str, battery_id: u8, expect_voltage: u32) {
    let Some(resp_payload) = ctx.send_command(name, &BATTERY_UUID, EC_BAT_GET_BST, &[battery_id])
    else {
        return;
    };

    // Response layout (4 LE u32): state@0, rate@4, capacity@8, voltage@12.
    let state = resp_payload.u32_at(0);
    let rate = resp_payload.u32_at(4);
    let capacity = resp_payload.u32_at(8);
    let voltage = resp_payload.u32_at(12);

    log::info!(
        "  GetBst[id={}]: state={:#x} rate={} capacity={} voltage={}",
        battery_id,
        state,
        rate,
        capacity,
        voltage,
    );

    // Exact equality: the mock is discharging only (DISCHARGING set, CHARGING /
    // CRITICAL / CHARGE_LIMITING clear), so the ACPI state word is exactly 0x1.
    if state != EXPECT_STATE_DISCHARGING {
        ctx.fail(name, "EC BST state != DISCHARGING-only (0x1)");
        return;
    }
    if rate != EXPECT_PRESENT_RATE {
        ctx.fail(name, "present_rate != EC mock value");
        return;
    }
    if capacity != EXPECT_REMAINING_CAPACITY {
        ctx.fail(name, "remaining_capacity != EC mock value");
        return;
    }
    if voltage != expect_voltage {
        ctx.fail(name, "present_voltage != EC mock value for battery id");
        return;
    }
    ctx.pass(name);
}
