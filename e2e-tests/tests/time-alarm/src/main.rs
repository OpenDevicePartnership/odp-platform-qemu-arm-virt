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
    SetRealTime = 3,
    GetWakeStatus = 4,
    ClearWakeStatus = 5,
    SetTimerValue = 6,
    GetTimerValue = 7,
    SetExpiredTimerPolicy = 8,
    GetExpiredTimerPolicy = 9,
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
    for (name, test) in [
        (
            "time_alarm_set_real_time_readback",
            test_set_real_time as fn(&mut E2eContext, &str) -> Option<()>,
        ),
        ("time_alarm_clear_wake_status", test_clear_wake_status),
        ("time_alarm_policy_set_get", test_policy_round_trip),
    ] {
        if test(ctx, name).is_some() {
            ctx.pass(name);
        }
    }
}

fn get_real_time(ctx: &mut E2eContext, name: &str) -> Option<Timestamp> {
    let payload = ctx.send_command(
        name,
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
    let Some(first) = get_real_time(ctx, "time_alarm_get_real_time") else {
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

    let Some(second) = get_real_time(ctx, "time_alarm_get_real_time") else {
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

fn require(ctx: &mut E2eContext, name: &str, condition: bool, reason: &str) -> Option<()> {
    if condition {
        Some(())
    } else {
        ctx.fail(name, reason);
        None
    }
}

fn scalar(ctx: &mut E2eContext, name: &str, command: TimeAlarmCommand, args: &[u8]) -> Option<u32> {
    Some(
        ctx.send_command(name, &TIME_ALARM_UUID, command.into(), args)?
            .u32_at(0),
    )
}

fn set(ctx: &mut E2eContext, name: &str, command: TimeAlarmCommand, args: &[u8]) -> Option<()> {
    let status = scalar(ctx, name, command, args)?;
    if status != 0 {
        log::error!("  {name}: setter status={status:#x}");
    }
    require(ctx, name, status == 0, "setter returned nonzero status")
}

fn timer_args(timer: u32, value: u32) -> [u8; 8] {
    let mut args = [0; 8];
    args[..4].copy_from_slice(&timer.to_le_bytes());
    args[4..].copy_from_slice(&value.to_le_bytes());
    args
}

fn disable_timers(ctx: &mut E2eContext, name: &str) -> Option<()> {
    for timer in 0..=1 {
        set(
            ctx,
            name,
            TimeAlarmCommand::SetTimerValue,
            &timer_args(timer, u32::MAX),
        )?;
    }
    Some(())
}

fn test_set_real_time(ctx: &mut E2eContext, name: &str) -> Option<()> {
    disable_timers(ctx, name)?;
    // 2026-09-17 12:00:00 UTC; the running EC mock has whole-second precision.
    let timestamp = [0xEA, 0x07, 9, 17, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    set(ctx, name, TimeAlarmCommand::SetRealTime, &timestamp)?;
    let mut previous = 12 * 3600;
    for sample in 0..2 {
        if sample == 1 {
            boot::stall(STALL_MICROSECONDS);
        }
        let actual = get_real_time(ctx, name)?;
        require(
            ctx,
            name,
            actual.year == 2026
                && actual.month == 9
                && actual.day == 17
                && actual.hour < 24
                && actual.minute < 60
                && actual.second < 60
                && actual.valid == 1
                && actual.milliseconds == 0
                && actual.timezone == 0
                && actual.daylight == 0
                && actual.reserved_bytes == [0; 3],
            "set time readback has incorrect date or metadata",
        )?;
        let seconds = actual.seconds_of_day();
        let minimum = if sample == 0 { 0 } else { 2 };
        require(
            ctx,
            name,
            seconds
                .checked_sub(previous)
                .is_some_and(|delta| (minimum..=6).contains(&delta)),
            "set time readback outside expected elapsed-second bounds",
        )?;
        previous = seconds;
    }
    Some(())
}

fn wake_status(ctx: &mut E2eContext, name: &str, timer: u32) -> Option<u32> {
    let status = scalar(
        ctx,
        name,
        TimeAlarmCommand::GetWakeStatus,
        &timer.to_le_bytes(),
    )?;
    require(
        ctx,
        name,
        status != u32::MAX,
        "GetWakeStatus returned error sentinel",
    )?;
    Some(status)
}

fn test_clear_wake_status(ctx: &mut E2eContext, name: &str) -> Option<()> {
    disable_timers(ctx, name)?;
    for timer in 0u32..=1 {
        set(
            ctx,
            name,
            TimeAlarmCommand::ClearWakeStatus,
            &timer.to_le_bytes(),
        )?;
        set(
            ctx,
            name,
            TimeAlarmCommand::SetExpiredTimerPolicy,
            &timer_args(timer, u32::MAX),
        )?;
        set(
            ctx,
            name,
            TimeAlarmCommand::SetTimerValue,
            &timer_args(timer, 1),
        )?;
    }
    let mut status = [0; 2];
    for _ in 0..2 {
        boot::stall(STALL_MICROSECONDS);
        status = [wake_status(ctx, name, 0)?, wake_status(ctx, name, 1)?];
        if status.iter().all(|value| value & 1 != 0) {
            break;
        }
    }
    require(
        ctx,
        name,
        status.iter().all(|value| value & 1 != 0),
        "both timers must expire before testing clear",
    )?;
    for timer in 0u32..=1 {
        set(
            ctx,
            name,
            TimeAlarmCommand::ClearWakeStatus,
            &timer.to_le_bytes(),
        )?;
        status[timer as usize] = 0;
        let actual = [wake_status(ctx, name, 0)?, wake_status(ctx, name, 1)?];
        require(
            ctx,
            name,
            actual == status,
            "clear must zero only the selected timer",
        )?;
    }
    disable_timers(ctx, name)
}

fn test_policy_round_trip(ctx: &mut E2eContext, name: &str) -> Option<()> {
    disable_timers(ctx, name)?;
    for timer in 0..=1 {
        let other = 1 - timer;
        set(
            ctx,
            name,
            TimeAlarmCommand::SetExpiredTimerPolicy,
            &timer_args(other, 45),
        )?;
        for policy in [45, 0] {
            set(
                ctx,
                name,
                TimeAlarmCommand::SetExpiredTimerPolicy,
                &timer_args(timer, policy),
            )?;
            let actual = scalar(
                ctx,
                name,
                TimeAlarmCommand::GetExpiredTimerPolicy,
                &timer.to_le_bytes(),
            )?;
            let unchanged = scalar(
                ctx,
                name,
                TimeAlarmCommand::GetExpiredTimerPolicy,
                &other.to_le_bytes(),
            )?;
            require(
                ctx,
                name,
                actual == policy && unchanged == 45,
                "policy readback or other timer's policy changed unexpectedly",
            )?;
        }
        // NEVER readback is indistinguishable from the getter's error sentinel.
        set(
            ctx,
            name,
            TimeAlarmCommand::SetExpiredTimerPolicy,
            &timer_args(timer, u32::MAX),
        )?;
        let unchanged = scalar(
            ctx,
            name,
            TimeAlarmCommand::GetExpiredTimerPolicy,
            &other.to_le_bytes(),
        )?;
        require(
            ctx,
            name,
            unchanged == 45,
            "setting NEVER changed the other timer's policy",
        )?;
    }
    Some(())
}
