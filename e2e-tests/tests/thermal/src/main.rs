//! E2E test: Thermal command family via FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!

#![no_main]
#![no_std]

extern crate alloc;

use test_support::{run_tests, E2eContext, THERMAL_UUID};
use uefi::prelude::*;

#[repr(u8)]
enum ThermalCommand {
    GetTmp = 1,
    SetThrs = 2,
    GetThrs = 3,
    SetScp = 4,
    GetVar = 5,
    SetVar = 6,
}

impl From<ThermalCommand> for u8 {
    fn from(command: ThermalCommand) -> Self {
        command as Self
    }
}

const SENSOR_ID: u8 = 0;
const MIN_DK: u32 = 2900;
const MAX_DK: u32 = 3200;
const WARN_LOW_DK: u32 = 3000;
const WARN_HIGH_DK: u32 = 3100;
const CRT_TEMP_DK: u32 = 3500;
const INVALID_PARAMETER: u32 = 1;
const VARIABLE_LEN: u16 = 4;
const CRT_TEMP_UUID: [u8; 16] = uuid::uuid!("218246e7-baf6-45f1-aa13-07e4845256b8").to_bytes_le();

#[entry]
fn main() -> Status {
    run_tests(test_thermal_command_family)
}

fn test_thermal_command_family(ctx: &mut E2eContext) {
    test_get_temperature(ctx);
    test_threshold_round_trip(ctx);
    test_variable_round_trip(ctx);
    test_set_scp_error(ctx);
}

fn test_get_temperature(ctx: &mut E2eContext) {
    const NAME: &str = "thermal_get_temperature";
    let Some(response) = ctx.send_command(
        NAME,
        &THERMAL_UUID,
        ThermalCommand::GetTmp.into(),
        &[SENSOR_ID],
    ) else {
        return;
    };
    let temperature = response.u32_at(0);
    log::info!("  GetTmp: temperature={} dK", temperature);
    if !(MIN_DK..=MAX_DK).contains(&temperature) {
        ctx.fail(NAME, "DeciKelvin outside EC mock range");
        return;
    }
    ctx.pass(NAME);
}

fn test_threshold_round_trip(ctx: &mut E2eContext) {
    const NAME: &str = "thermal_set_get_threshold";
    let mut set_args = [0u8; 13];
    set_args[0] = SENSOR_ID;
    set_args[1..5].copy_from_slice(&0u32.to_le_bytes());
    set_args[5..9].copy_from_slice(&WARN_LOW_DK.to_le_bytes());
    set_args[9..13].copy_from_slice(&WARN_HIGH_DK.to_le_bytes());

    let Some(set_response) = ctx.send_command(
        NAME,
        &THERMAL_UUID,
        ThermalCommand::SetThrs.into(),
        &set_args,
    ) else {
        return;
    };
    if set_response.u32_at(0) != 0 {
        ctx.fail(NAME, "SetThrs returned non-zero status");
        return;
    }

    let Some(get_response) = ctx.send_command(
        NAME,
        &THERMAL_UUID,
        ThermalCommand::GetThrs.into(),
        &[SENSOR_ID],
    ) else {
        return;
    };
    let actual = (
        get_response.u32_at(0),
        get_response.u32_at(4),
        get_response.u32_at(8),
    );
    log::info!(
        "  Set/GetThrs: timeout={} low={} high={}",
        actual.0,
        actual.1,
        actual.2,
    );
    if actual != (0, WARN_LOW_DK, WARN_HIGH_DK) {
        ctx.fail(NAME, "GetThrs did not return EC-stored thresholds");
        return;
    }
    ctx.pass(NAME);
}

fn test_variable_round_trip(ctx: &mut E2eContext) {
    const NAME: &str = "thermal_set_get_variable";
    let mut set_args = [0u8; 23];
    set_args[0] = SENSOR_ID;
    set_args[1..3].copy_from_slice(&VARIABLE_LEN.to_le_bytes());
    set_args[3..19].copy_from_slice(&CRT_TEMP_UUID);
    set_args[19..23].copy_from_slice(&CRT_TEMP_DK.to_le_bytes());

    let Some(set_response) = ctx.send_command(
        NAME,
        &THERMAL_UUID,
        ThermalCommand::SetVar.into(),
        &set_args,
    ) else {
        return;
    };
    if set_response.u32_at(0) != 0 {
        ctx.fail(NAME, "SetVar returned non-zero status");
        return;
    }

    let mut get_args = [0u8; 19];
    get_args[0] = SENSOR_ID;
    get_args[1..3].copy_from_slice(&VARIABLE_LEN.to_le_bytes());
    get_args[3..19].copy_from_slice(&CRT_TEMP_UUID);
    let Some(get_response) = ctx.send_command(
        NAME,
        &THERMAL_UUID,
        ThermalCommand::GetVar.into(),
        &get_args,
    ) else {
        return;
    };
    let value = get_response.u32_at(0);
    log::info!("  Set/GetVar CRT_TEMP: value={} dK", value);
    if value != CRT_TEMP_DK {
        ctx.fail(NAME, "GetVar did not return EC-stored CRT_TEMP");
        return;
    }
    ctx.pass(NAME);
}

fn test_set_scp_error(ctx: &mut E2eContext) {
    const NAME: &str = "thermal_set_scp_invalid_parameter";
    let mut args = [0u8; 13];
    args[0] = SENSOR_ID;
    args[1..5].copy_from_slice(&1u32.to_le_bytes());
    args[5..9].copy_from_slice(&75u32.to_le_bytes());
    args[9..13].copy_from_slice(&25u32.to_le_bytes());

    let Some(response) =
        ctx.send_command(NAME, &THERMAL_UUID, ThermalCommand::SetScp.into(), &args)
    else {
        return;
    };
    let status = response.u32_at(0);
    log::info!("  SetScp: status={}", status);
    if status != INVALID_PARAMETER {
        ctx.fail(NAME, "SetScp did not return EC InvalidParameter");
        return;
    }
    ctx.pass(NAME);
}
