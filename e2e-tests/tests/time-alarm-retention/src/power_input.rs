//! Emulated source-switch command-path checks, not transition-time CPU resume.
// SPDX-License-Identifier: MIT

use uefi::{
    boot::{self, EventType, TimerTrigger, Tpl},
    proto::console::text::Key,
    system,
};

use crate::{
    acknowledge, attempt, counter, disarm, frequency, require, scalar, set, E2eContext, Fixture,
    TestResult, ALARM_SECONDS, GET_TIMER, GET_WAKE, SET_POLICY, SET_TIMER,
};

fn source_request(sequence: u8, source: u32) -> TestResult {
    let source = if source == 0 { "ac" } else { "dc" };
    let key_event = system::with_stdin(|input| {
        input
            .reset(false)
            .map_err(|_| "cannot reset source-ack input")?;
        input
            .wait_for_key_event()
            .ok_or("source-ack input has no event")
    })?;
    // No callback or context crosses the event lifetime.
    let deadline = unsafe { boot::create_event(EventType::TIMER, Tpl::APPLICATION, None, None) }
        .map_err(|_| "cannot create source-ack deadline")?;
    let mut events = [deadline, key_event];
    let result = (|| {
        boot::set_timer(&events[0], TimerTrigger::Relative(100_000_000))
            .map_err(|_| "cannot arm source-ack deadline")?;
        log::info!("TA_SOURCE {sequence} {source}");
        loop {
            let event = boot::wait_for_event(&mut events).map_err(|_| "source-ack wait failed")?;
            require(
                event == 1,
                "source application was not acknowledged within ten seconds",
            )?;
            match system::with_stdin(|input| input.read_key())
                .map_err(|_| "cannot read source acknowledgment")?
            {
                Some(Key::Printable(key)) if u16::from(key) == u16::from(b'0' + sequence) => break,
                None => continue,
                _ => return Err("unexpected source acknowledgment sequence"),
            }
        }
        log::info!("TA_SOURCE_ACK {sequence} {source}");
        Ok(())
    })();
    let [deadline, _] = events;
    let closed = boot::close_event(deadline).map_err(|_| "cannot close source-ack deadline");
    result.and(closed)
}

fn guard(ctx: &mut E2eContext, fixture: &mut Fixture, source: u32) -> TestResult {
    let observation = fixture.standby(counter())?;
    log::info!(
        "POWER_INPUT guard smc={} irq={} ticks={} hz={} gpio={:#x} mis={:#x} timer_ctl={:#x}",
        observation.psci,
        observation.interrupt,
        observation.elapsed,
        frequency(),
        observation.gpio,
        observation.masked,
        observation.timer_control,
    );
    require(
        observation.valid(frequency(), false),
        "source-switch guard had an unexpected wake",
    )?;
    fixture.validate_isr(false)?;
    require(
        scalar(ctx, GET_WAKE, source, None)? == 1 && fixture.pin_low(),
        "inactive/orphaned timer must be expired without GPIO1 or a wake latch",
    )?;
    fixture.clear_pending()
}

fn await_wake(ctx: &mut E2eContext, fixture: &Fixture, source: u32) -> TestResult {
    let deadline = counter() + 10 * frequency();
    // This polls command completion while awake; it is not CPU-wake evidence.
    let event = unsafe { boot::create_event(EventType::TIMER, Tpl::APPLICATION, None, None) }
        .map_err(|_| "cannot create wake observation event")?;
    let mut events = [event];
    let result = (|| {
        boot::set_timer(&events[0], TimerTrigger::Periodic(100_000))
            .map_err(|_| "cannot arm wake observation event")?;
        loop {
            let status = scalar(ctx, GET_WAKE, source, None)?;
            require(
                status == 1 || status == 3,
                "unexpected source-switch wake status",
            )?;
            if status == 3 && !fixture.pin_low() {
                log::info!(
                    "POWER_INPUT source-switch request observed: status=3 GPIO1=high; CPU awake"
                );
                return Ok(());
            }
            require(
                counter() < deadline,
                "INSTANTLY did not assert its latch and GPIO1",
            )?;
            boot::wait_for_event(&mut events).map_err(|_| "wake observation wait failed")?;
        }
    })();
    let [event] = events;
    let closed = boot::close_event(event).map_err(|_| "cannot close wake observation event");
    result.and(closed)
}

pub fn run(ctx: &mut E2eContext, fixture: &mut Fixture, source: u32) -> TestResult {
    log::info!("POWER_INPUT emulated source-switch command-path test; not Windows resume");
    source_request(0, source)?;
    require(
        scalar(ctx, GET_WAKE, 0, None)? == 0
            && scalar(ctx, GET_WAKE, 1, None)? == 0
            && fixture.pin_low(),
        "runtime-input fixture must start with both timers disabled and GPIO1 low",
    )?;
    attempt(ctx, fixture, source, true, true)?;
    ctx.pass("power_input_startup_retention");

    for (sequence, policy, name) in [
        (1, 0, "power_input_instantly"),
        (3, u32::MAX, "power_input_never"),
    ] {
        disarm(ctx)?;
        acknowledge(ctx, fixture)?;
        source_request(sequence, 1 - source)?;
        set(ctx, SET_POLICY, source, Some(policy))?;
        set(ctx, SET_TIMER, source, Some(ALARM_SECONDS))?;
        require(
            (3..=ALARM_SECONDS).contains(&scalar(ctx, GET_TIMER, source, None)?),
            "insufficient inactive alarm time remaining",
        )?;
        guard(ctx, fixture, source)?;
        source_request(sequence + 1, source)?;
        if policy == 0 {
            await_wake(ctx, fixture, source)?;
        } else {
            guard(ctx, fixture, source)?;
        }
        require(
            scalar(ctx, GET_WAKE, 1 - source, None)? == 0,
            "the other timer unexpectedly latched during a source switch",
        )?;
        acknowledge(ctx, fixture)?;
        disarm(ctx)?;
        ctx.pass(name);
    }
    log::info!("TA_SOURCE_DONE");
    Ok(())
}
