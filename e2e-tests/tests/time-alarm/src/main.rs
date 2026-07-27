//! E2E test: TimeAlarm real-time and timer set/get via FF-A Direct Request v2.
//!
//! SPDX-License-Identifier: MIT
//!

#![no_main]
#![no_std]

extern crate alloc;

use ffa::DirectMessagePayload;
use test_support::{run_tests, E2eContext, TIME_ALARM_UUID};
use uefi::{boot, prelude::*};

#[repr(u8)]
enum TimeAlarmCommand {
    GetRealTime = 2,
    SetTimerValue = 6,
    GetTimerValue = 7,
}

impl From<TimeAlarmCommand> for u8 {
    fn from(command: TimeAlarmCommand) -> Self {
        command as Self
    }
}

const AC_TIMER_ID: u32 = 0;
const TIMER_SECONDS: u32 = 300;
const MIN_INITIAL_SECONDS: u32 = 290;
const MIN_COUNTDOWN_DELTA: u32 = 2;
const MAX_COUNTDOWN_DELTA: u32 = 6;
const STALL_MICROSECONDS: usize = 3_000_000;
const ACPI_TIMESTAMP_LEN: usize = 16;

#[derive(Clone, Copy)]
struct Timestamp {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    valid: u8,
    milliseconds: u16,
    timezone: i16,
    daylight: u8,
    // ACPI wire-reserved bytes, not Rust struct padding.
    reserved_bytes: [u8; 3],
}

impl Timestamp {
    fn parse(payload: &DirectMessagePayload) -> Self {
        Self {
            year: u16::from_le_bytes([payload.u8_at(0), payload.u8_at(1)]),
            month: payload.u8_at(2),
            day: payload.u8_at(3),
            hour: payload.u8_at(4),
            minute: payload.u8_at(5),
            second: payload.u8_at(6),
            valid: payload.u8_at(7),
            milliseconds: u16::from_le_bytes([payload.u8_at(8), payload.u8_at(9)]),
            timezone: i16::from_le_bytes([payload.u8_at(10), payload.u8_at(11)]),
            daylight: payload.u8_at(12),
            reserved_bytes: [
                payload.u8_at(ACPI_TIMESTAMP_LEN - 3),
                payload.u8_at(ACPI_TIMESTAMP_LEN - 2),
                payload.u8_at(ACPI_TIMESTAMP_LEN - 1),
            ],
        }
    }

    fn seconds_of_day(self) -> u32 {
        u32::from(self.hour) * 3600 + u32::from(self.minute) * 60 + u32::from(self.second)
    }

    fn is_expected_mock_shape(self) -> bool {
        self.year == 1970
            && self.month == 1
            && self.day == 1
            && self.hour < 24
            && self.minute < 60
            && self.second < 60
            && self.valid == 1
            && self.milliseconds < 1000
            && self.timezone == 0
            && self.daylight == 0
            && self.reserved_bytes == [0, 0, 0]
    }
}

#[entry]
fn main() -> Status {
    run_tests(test_time_alarm_command_family)
}

fn test_time_alarm_command_family(ctx: &mut E2eContext) {
    test_get_real_time(ctx);
    test_timer_value_round_trip(ctx);
}

fn get_real_time(ctx: &mut E2eContext) -> Option<Timestamp> {
    let payload = ctx.send_command(
        "time_alarm_get_real_time",
        &TIME_ALARM_UUID,
        TimeAlarmCommand::GetRealTime.into(),
        &[],
    )?;
    Some(Timestamp::parse(&payload))
}

fn get_timer_value(ctx: &mut E2eContext, test_name: &str) -> Option<u32> {
    let args = AC_TIMER_ID.to_le_bytes();
    let payload = ctx.send_command(
        test_name,
        &TIME_ALARM_UUID,
        TimeAlarmCommand::GetTimerValue.into(),
        &args,
    )?;
    Some(payload.u32_at(0))
}

fn test_get_real_time(ctx: &mut E2eContext) {
    let Some(first) = get_real_time(ctx) else {
        return;
    };
    if !first.is_expected_mock_shape() {
        ctx.fail(
            "time_alarm_get_real_time",
            "first timestamp does not match EC mock shape",
        );
        return;
    }

    boot::stall(STALL_MICROSECONDS);

    let Some(second) = get_real_time(ctx) else {
        return;
    };
    if !second.is_expected_mock_shape() {
        ctx.fail(
            "time_alarm_get_real_time",
            "second timestamp does not match EC mock shape",
        );
        return;
    }

    let Some(delta) = second.seconds_of_day().checked_sub(first.seconds_of_day()) else {
        ctx.fail("time_alarm_get_real_time", "EC time moved backwards");
        return;
    };

    log::info!(
        "  GetRealTime: first={:02}:{:02}:{:02}.{:03} \
         second={:02}:{:02}:{:02}.{:03} delta={}s",
        first.hour,
        first.minute,
        first.second,
        first.milliseconds,
        second.hour,
        second.minute,
        second.second,
        second.milliseconds,
        delta,
    );

    if !(2..=6).contains(&delta) {
        ctx.fail(
            "time_alarm_get_real_time",
            "EC clock delta outside 2..=6 seconds",
        );
        return;
    }

    ctx.pass("time_alarm_get_real_time");
}

fn test_timer_value_round_trip(ctx: &mut E2eContext) {
    const NAME: &str = "time_alarm_timer_set_get";

    let mut set_args = [0u8; 8];
    set_args[..4].copy_from_slice(&AC_TIMER_ID.to_le_bytes());
    set_args[4..].copy_from_slice(&TIMER_SECONDS.to_le_bytes());
    let Some(set_response) = ctx.send_command(
        NAME,
        &TIME_ALARM_UUID,
        TimeAlarmCommand::SetTimerValue.into(),
        &set_args,
    ) else {
        return;
    };
    let status = set_response.u32_at(0);
    if status != 0 {
        log::error!("  SetTimerValue: status={}", status);
        ctx.fail(NAME, "SetTimerValue returned non-zero status");
        return;
    }

    let Some(first) = get_timer_value(ctx, NAME) else {
        return;
    };
    if !(MIN_INITIAL_SECONDS..=TIMER_SECONDS).contains(&first) {
        log::error!(
            "  GetTimerValue: initial={}s expected={}..={}s",
            first,
            MIN_INITIAL_SECONDS,
            TIMER_SECONDS,
        );
        ctx.fail(NAME, "initial timer value outside 290..=300 seconds");
        return;
    }

    boot::stall(STALL_MICROSECONDS);

    let Some(second) = get_timer_value(ctx, NAME) else {
        return;
    };
    let Some(delta) = first.checked_sub(second) else {
        log::error!(
            "  GetTimerValue: first={}s second={}s (timer increased)",
            first,
            second,
        );
        ctx.fail(NAME, "EC timer value increased");
        return;
    };

    log::info!(
        "  Set/GetTimerValue: first={}s second={}s delta={}s",
        first,
        second,
        delta,
    );

    if !(MIN_COUNTDOWN_DELTA..=MAX_COUNTDOWN_DELTA).contains(&delta) {
        ctx.fail(NAME, "EC timer delta outside 2..=6 seconds");
        return;
    }

    ctx.pass(NAME);
}
