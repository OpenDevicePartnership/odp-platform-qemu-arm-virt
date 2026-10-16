//! Two-QEMU CPU-retention acceptance, not OS sleep/resume.
//!
//! SPDX-License-Identifier: MIT

#![no_main]
#![no_std]

mod interrupt;
mod platform;
mod power_input;

use platform::{counter, frequency, Fixture};
use test_support::{run_tests, E2eContext, TIME_ALARM_UUID};
use uefi::{boot, cstr16, prelude::*, proto::shell_params::ShellParameters};

type TestResult<T = ()> = Result<T, &'static str>;

const GET_WAKE: u8 = 4;
const CLEAR_WAKE: u8 = 5;
const SET_TIMER: u8 = 6;
const GET_TIMER: u8 = 7;
const SET_POLICY: u8 = 8;
const ALARM_SECONDS: u32 = 5;

enum Mode {
    Wake { source: u32, connected: bool },
    PowerInput(u32),
}

#[entry]
fn main() -> Status {
    run_tests(|ctx| {
        if let Err(reason) = run(ctx) {
            ctx.fail("time_alarm_retention", reason);
        }
    })
}

fn require(condition: bool, reason: &'static str) -> TestResult {
    if condition {
        Ok(())
    } else {
        Err(reason)
    }
}

fn arguments() -> TestResult<Mode> {
    let params = boot::open_protocol_exclusive::<ShellParameters>(boot::image_handle())
        .map_err(|_| "shell parameters unavailable")?;
    let mut args = params.args().skip(1);
    let selected = args.next();
    require(
        params.args_len() == 3,
        "expected source and wire arguments, or power-input and source",
    )?;
    if selected == Some(cstr16!("power-input")) {
        return match args.next() {
            Some(value) if value == cstr16!("ac") => Ok(Mode::PowerInput(0)),
            Some(value) if value == cstr16!("dc") => Ok(Mode::PowerInput(1)),
            _ => Err("power-input requires an explicit ac or dc startup source"),
        };
    }
    let source = match selected {
        Some(arg) if arg == cstr16!("ac") => 0,
        Some(arg) if arg == cstr16!("dc") => 1,
        _ => return Err("source must be explicitly ac or dc"),
    };
    let connected = match args.next() {
        Some(arg) if arg == cstr16!("connected") => true,
        Some(arg) if arg == cstr16!("disconnected") => false,
        _ => return Err("wire must be connected or disconnected"),
    };
    Ok(Mode::Wake { source, connected })
}

fn scalar(ctx: &mut E2eContext, command: u8, timer: u32, value: Option<u32>) -> TestResult<u32> {
    let mut args = [0u8; 8];
    args[..4].copy_from_slice(&timer.to_le_bytes());
    if let Some(value) = value {
        args[4..].copy_from_slice(&value.to_le_bytes());
    }
    ctx.send_command(
        "time_alarm_retention_command",
        &TIME_ALARM_UUID,
        command,
        &args[..if value.is_some() { 8 } else { 4 }],
    )
    .map(|response| response.u32_at(0))
    .ok_or("normal TimeAlarm relay command failed")
}

fn set(ctx: &mut E2eContext, command: u8, timer: u32, value: Option<u32>) -> TestResult {
    let status = scalar(ctx, command, timer, value)?;
    if status != 0 {
        log::error!("TimeAlarm command={command} timer={timer} status={status:#x}");
    }
    require(status == 0, "TimeAlarm setter failed")
}

fn disarm(ctx: &mut E2eContext) -> TestResult {
    let mut result = Ok(());
    for timer in 0..=1 {
        result = result.and(set(ctx, SET_TIMER, timer, Some(u32::MAX)));
        result = result.and(set(ctx, CLEAR_WAKE, timer, None));
    }
    result
}

fn acknowledge(ctx: &mut E2eContext, fixture: &Fixture) -> TestResult {
    for timer in 0..=1 {
        set(ctx, CLEAR_WAKE, timer, None)?;
    }
    // Only housekeeping polls: no polling substitutes for the standby call.
    for _ in 0..20 {
        let clear = scalar(ctx, GET_WAKE, 0, None)? == 0 && scalar(ctx, GET_WAKE, 1, None)? == 0;
        if clear && fixture.pin_low() {
            return fixture.clear_pending();
        }
        boot::stall(10_000);
    }
    Err("clear did not deassert GPIO1 within bounded acknowledgements")
}

fn attempt(
    ctx: &mut E2eContext,
    fixture: &mut Fixture,
    timer: u32,
    expect_wake: bool,
    expect_latch: bool,
) -> TestResult {
    disarm(ctx)?;
    acknowledge(ctx, fixture)?;
    set(ctx, SET_POLICY, timer, Some(0))?;
    set(ctx, SET_TIMER, timer, Some(ALARM_SECONDS))?;
    let sampled = counter();
    let remaining = scalar(ctx, GET_TIMER, timer, None)?;
    require(
        (3..=ALARM_SECONDS).contains(&remaining),
        "insufficient EC alarm time remaining",
    )?;
    let observation = fixture.standby(sampled)?;
    log::info!(
        "RETENTION timer={} expected_wake={} smc={} ticks={} hz={} irq={} gpio={:#x} mis={:#x} timer_ctl={:#x}",
        timer, expect_wake, observation.psci, observation.elapsed, frequency(),
        observation.interrupt, observation.gpio, observation.masked, observation.timer_control,
    );
    require(
        observation.valid(frequency(), expect_wake),
        "return lacks exclusive GPIO1 wake or identified guard evidence",
    )?;
    fixture.validate_isr(expect_wake)?;
    let status = scalar(ctx, GET_WAKE, timer, None)?;
    require(
        status == if expect_latch { 3 } else { 1 },
        "EC expiry/wake latch disagrees with selected fixture or wire case",
    )?;
    acknowledge(ctx, fixture)?;
    disarm(ctx)
}

fn run(ctx: &mut E2eContext) -> TestResult {
    let (source, connected, power_input) = match arguments()? {
        Mode::Wake { source, connected } => (source, connected, false),
        Mode::PowerInput(source) => (source, true, true),
    };
    let wire = if connected {
        "connected"
    } else {
        "disconnected"
    };
    log::info!(
        "RETENTION fixture={} wire={wire}",
        if source == 0 { "ac" } else { "dc" },
    );
    let mut fixture = Fixture::new()?;
    let mut outcome = (|| {
        if power_input {
            power_input::run(ctx, &mut fixture, source)?;
        } else if connected {
            attempt(ctx, &mut fixture, 1 - source, false, false)?;
            ctx.pass("retention_inactive_alarm_guard");
            attempt(ctx, &mut fixture, source, true, true)?;
            ctx.pass("retention_selected_alarm");
            attempt(ctx, &mut fixture, source, true, true)?;
            ctx.pass("retention_clear_rearm");
        } else {
            attempt(ctx, &mut fixture, source, false, true)?;
            ctx.pass("retention_disconnected_wire_guard");
        }
        Ok(())
    })();
    let mut record_cleanup = |result| {
        if let Err(reason) = result {
            log::error!("Retention cleanup: {reason}");
        }
        outcome = outcome.and(result);
    };
    record_cleanup(disarm(ctx));
    record_cleanup(acknowledge(ctx, &fixture));
    record_cleanup(fixture.restore());
    outcome
}
