// SPDX-License-Identifier: MIT

use core::{
    arch::asm,
    ffi::c_void,
    ptr,
    sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, Ordering},
};
use uefi::{
    boot::ScopedProtocol,
    runtime::{self, ResetType},
    Status,
};

use crate::{
    evidence::Observation,
    gpio_irq::{self, BIT as IRQ_BIT, IRQ},
    protocol::{self, HardwareInterrupt},
    require, TestResult,
};

const GPIO: usize = 0x0903_0000;
const GICD: usize = 0x0800_0000;
const GICR: usize = 0x080a_0000;
const SGI: usize = GICR + 0x10000;
const PIN: u32 = 2;
const GUARD: u32 = 1 << 27;
const CPU_SUSPEND64: u64 = 0xc400_0001;
const GPIO_REGISTERS: [usize; 6] = [0x400, 0x404, 0x408, 0x40c, 0x410, 0x420];

static PROTOCOL: AtomicPtr<HardwareInterrupt> = AtomicPtr::new(ptr::null_mut());
static ISR_PIN: AtomicU32 = AtomicU32::new(0);
static ISR_ERROR: AtomicBool = AtomicBool::new(false);

fn read(address: usize) -> u32 {
    // Only the pinned QEMU virt device addresses are used by this fixture.
    unsafe { ptr::read_volatile(address as *const u32) }
}

fn write(address: usize, value: u32) {
    unsafe { ptr::write_volatile(address as *mut u32, value) }
}

fn read64(address: usize) -> u64 {
    unsafe { ptr::read_volatile(address as *const u64) }
}

macro_rules! register {
    ($name:literal) => {{
        let value: u64;
        unsafe { asm!(concat!("mrs {}, ", $name), out(reg) value, options(nostack, nomem)); }
        value
    }};
}

pub fn counter() -> u64 {
    unsafe {
        asm!("isb", options(nostack));
    }
    register!("cntvct_el0")
}

pub fn frequency() -> u64 {
    register!("cntfrq_el0")
}

fn mask_irq() -> u64 {
    let saved = register!("daif");
    unsafe {
        asm!("msr daifset, #2", "isb", options(nostack));
    }
    saved
}

fn restore_irq(saved: u64) {
    unsafe {
        asm!("msr daif, {}", "isb", in(reg) saved, options(nostack));
    }
}

fn timer(control: u64, compare: u64) {
    unsafe {
        asm!(
            "msr cntv_ctl_el0, {masked}", "isb",
            "msr cntv_cval_el0, {compare}", "msr cntv_ctl_el0, {control}", "isb",
            masked = in(reg) 2u64, compare = in(reg) compare, control = in(reg) control,
            options(nostack),
        );
    }
}

fn smc(function: u64, arg: u64) -> i32 {
    ffa::raw_smc(
        function, arg, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    )[0] as i32
}

fn synchronize_gic() -> TestResult {
    let deadline = counter() + frequency() / 10;
    unsafe {
        asm!("dsb sy", options(nostack));
    }
    while read(GICD) & (1 << 31) != 0 || read(GICR) & (1 << 3) != 0 {
        require(counter() < deadline, "GIC register write did not complete")?;
    }
    unsafe {
        asm!("dsb sy", "isb", options(nostack));
    }
    Ok(())
}

fn gpio_irq_enabled() -> bool {
    gpio_irq::enabled(read(GICD + gpio_irq::ENABLE_OFFSET))
}

fn set_gpio_irq_configuration(configuration: u32) -> TestResult {
    require(
        !gpio_irq_enabled(),
        "GPIO IRQ must be disabled before changing its trigger",
    )?;
    let address = GICD + gpio_irq::CONFIG_OFFSET;
    let expected = gpio_irq::with_configuration(read(address), configuration);
    write(address, expected);
    synchronize_gic()?;
    let actual = read(address);
    if actual != expected {
        log::error!("GPIO ICFGR2 readback={actual:#x}, expected={expected:#x}");
    }
    require(
        actual == expected,
        "GPIO trigger configuration readback mismatch",
    )
}

unsafe extern "efiapi" fn gpio_interrupt(source: usize, _: *mut c_void) {
    ISR_PIN.store(read(GPIO + 0x418), Ordering::SeqCst);
    write(GPIO + 0x410, 0);
    unsafe {
        asm!("dsb sy", options(nostack));
    }
    let protocol = PROTOCOL.load(Ordering::SeqCst);
    // Patina acknowledges on dispatch, but a registered handler owns its EOI.
    let status = unsafe { ((*protocol).eoi)(protocol, source) };
    ISR_ERROR.store(source != IRQ || status != Status::SUCCESS, Ordering::SeqCst);
}

pub struct Fixture {
    _protocol: ScopedProtocol<HardwareInterrupt>,
    interface: *mut HardwareInterrupt,
    gpio: [u32; 6],
    irq_configuration: u32,
    words: usize,
    registered: bool,
    restored: bool,
}

impl Fixture {
    pub fn new() -> TestResult<Self> {
        let mut fixture = Self::inspect()?;
        fixture.restored = false;
        let configured = fixture.configure();
        if let Err(reason) = configured {
            fixture.restore()?;
            return Err(reason);
        }
        Ok(fixture)
    }

    fn inspect() -> TestResult<Self> {
        let current_el = register!("CurrentEL");
        log::info!("RETENTION CurrentEL={}", current_el >> 2);
        require(matches!(current_el, 4 | 8), "requires NS EL1 or EL2")?;
        require(
            register!("daif") & 0x80 == 0,
            "UEFI IRQ dispatch is disabled",
        )?;
        let mpidr = register!("mpidr_el1");
        log::info!("RETENTION MPIDR={mpidr:#x}");
        require(mpidr & 0xff00ffffff == 0, "fixture requires QEMU boot CPU")?;
        require(frequency() != 0, "architectural counter frequency is zero")?;
        require(
            smc(0x8400_000a, CPU_SUSPEND64) >= 0,
            "PSCI CPU_SUSPEND64 unsupported",
        )?;
        // TF-A 842ce6391: qemu_pm_idle_states accepts 1; cpu_standby is DSB/WFI.
        let redistributor_affinity = read64(GICR + 8) >> 32;
        let gpio_route = read64(GICD + 0x6000 + IRQ * 8);
        log::info!(
            "RETENTION GICR={GICR:#x} affinity={redistributor_affinity:#x} GPIO_IROUTER={gpio_route:#x}"
        );
        require(
            redistributor_affinity == 0,
            "redistributor does not target boot CPU",
        )?;
        require(
            read(GICR) & 1 == 0,
            "LPI isolation is not supported by this fixture",
        )?;
        require(
            read(GICD) & (1 << 4) != 0,
            "GIC non-secure affinity routing is disabled",
        )?;
        require(gpio_route == 0, "GPIO IRQ routes away from boot CPU")?;
        let priority_mask = register!("icc_pmr_el1");
        let gpio_priority = (read(GICD + 0x400 + (IRQ & !3)) >> ((IRQ & 3) * 8)) & 0xff;
        let guard_priority = read(SGI + 0x418) >> 24;
        require(
            u64::from(gpio_priority) < priority_mask
                && u64::from(guard_priority) < priority_mask
                && register!("icc_igrpen1_el1") & 1 != 0
                && register!("icc_rpr_el1") == 0xff,
            "GIC priorities/group delivery would block the wake or guard",
        )?;
        require(
            read(GICD + 0x204) & IRQ_BIT == 0 && read(GICD + 0x304) & IRQ_BIT == 0,
            "GPIO IRQ is already pending or active",
        )?;
        let mut protocol = protocol::open()?;
        let interface = ptr::from_mut(&mut *protocol);
        // Patina 22.1's SPI getters misindex saved context and misdecode ICFGR.
        let enabled_word = read(GICD + gpio_irq::ENABLE_OFFSET);
        let configuration_word = read(GICD + gpio_irq::CONFIG_OFFSET);
        let enabled = gpio_irq::enabled(enabled_word);
        log::warn!("RETENTION bypassing known-bad Patina 22.1 SPI state/trigger getters");
        log::info!(
            "RETENTION HardwareInterrupt2 available; GICD INTID39 ISENABLER1={enabled_word:#x} ICFGR2={configuration_word:#x}"
        );
        require(
            !enabled,
            "GPIO interrupt already enabled; refusing to take ownership",
        )?;
        Ok(Self {
            _protocol: protocol,
            interface,
            gpio: GPIO_REGISTERS.map(|offset| read(GPIO + offset)),
            irq_configuration: gpio_irq::configuration(configuration_word),
            words: ((read(GICD + 4) & 31) + 1) as usize,
            registered: false,
            // Read-only discovery does not require device-state restoration.
            restored: true,
        })
    }

    fn configure(&mut self) -> TestResult {
        require(self.pin_low(), "GPIO1 was asserted before fixture setup")?;
        write(GPIO + 0x410, 0);
        unsafe {
            asm!("dsb sy", options(nostack));
        }
        PROTOCOL.store(self.interface, Ordering::SeqCst);
        unsafe {
            protocol::check(
                ((*self.interface).register)(self.interface, IRQ, Some(gpio_interrupt)),
                "claim GPIO IRQ (must be unowned)",
            )?;
        }
        self.registered = true;
        // Registration enables the source; ICFGR changes require it disabled.
        write(GICD + gpio_irq::DISABLE_OFFSET, IRQ_BIT);
        synchronize_gic()?;
        set_gpio_irq_configuration(0)?;
        write(GPIO + 0x400, self.gpio[0] & !PIN);
        write(GPIO + 0x404, self.gpio[1] | PIN);
        write(GPIO + 0x408, self.gpio[2] & !PIN);
        write(GPIO + 0x40c, self.gpio[3] | PIN);
        write(GPIO + 0x420, self.gpio[5] & !PIN);
        self.clear_pending()?;
        write(GICD + gpio_irq::ENABLE_OFFSET, IRQ_BIT);
        synchronize_gic()?;
        require(
            gpio_irq_enabled(),
            "GPIO IRQ did not enable after configuration",
        )
    }

    pub fn pin_low(&self) -> bool {
        read(GPIO + 8) == 0
    }

    pub fn clear_pending(&self) -> TestResult {
        require(
            self.pin_low(),
            "cannot clear GPIO pending state while pin1 is high",
        )?;
        write(GPIO + 0x410, 0);
        write(GPIO + 0x41c, PIN);
        write(GICD + 0x284, IRQ_BIT);
        synchronize_gic()?;
        require(
            read(GPIO + 0x414) & PIN == 0 && read(GICD + 0x204) & IRQ_BIT == 0,
            "GPIO1 pending state did not clear",
        )
    }

    pub fn validate_isr(&self, wake: bool) -> TestResult {
        require(
            !ISR_ERROR.load(Ordering::SeqCst),
            "GPIO ISR source or EOI failed",
        )?;
        require(
            ISR_PIN.load(Ordering::SeqCst) == if wake { PIN } else { 0 },
            "GPIO1 ISR evidence disagrees with pre-dispatch wake cause",
        )
    }

    pub fn standby(&mut self, sampled: u64) -> TestResult<Observation> {
        ISR_PIN.store(0, Ordering::SeqCst);
        ISR_ERROR.store(false, Ordering::SeqCst);
        let daif = mask_irq();
        let saved_control = register!("cntv_ctl_el0") & 3;
        let saved_compare = register!("cntv_cval_el0");
        let saved_pending = read(SGI + 0x200) & GUARD;
        let mut enabled = [0; 32];
        enabled[0] = read(SGI + 0x100);
        write(SGI + 0x180, u32::MAX);
        for (word, state) in enabled.iter_mut().enumerate().take(self.words).skip(1) {
            *state = read(GICD + 0x100 + word * 4);
            // Non-secure accesses leave secure interrupt enables untouched.
            write(GICD + 0x180 + word * 4, u32::MAX);
        }
        let result = (|| {
            synchronize_gic()?;
            timer(2, saved_compare);
            write(SGI + 0x280, GUARD);
            let deadline = counter() + 10 * frequency();
            timer(1, deadline);
            write(GPIO + 0x410, PIN);
            write(SGI + 0x100, GUARD);
            write(GICD + 0x104, IRQ_BIT);
            synchronize_gic()?;
            require(
                register!("cntv_ctl_el0") & 3 == 1 && register!("cntv_cval_el0") == deadline,
                "guard timer did not arm",
            )?;
            require(
                read(GPIO + 0x410) == PIN
                    && read(SGI + 0x100) == GUARD
                    && (1..self.words).all(|word| {
                        read(GICD + 0x100 + word * 4) == if word == 1 { IRQ_BIT } else { 0 }
                    }),
                "unrelated non-secure IRQs were not isolated",
            )?;
            require(
                self.pin_low()
                    && read(GPIO + 0x414) & PIN == 0
                    && read(GICD + 0x204) & IRQ_BIT == 0,
                "GPIO1 asserted before CPU standby",
            )?;
            require(
                register!("icc_hppir1_el1") == 1023,
                "an IRQ was pending before standby",
            )?;
            let start = counter();
            require(
                start - sampled < frequency(),
                "EC remaining-time sample became stale",
            )?;
            require(
                deadline - start >= 9 * frequency(),
                "guard deadline too close",
            )?;
            let psci = smc(CPU_SUSPEND64, 1);
            let elapsed = counter() - start;
            Ok(Observation {
                psci,
                elapsed,
                interrupt: register!("icc_hppir1_el1"),
                gpio: read(GPIO + 0x3fc),
                masked: read(GPIO + 0x418),
                timer_control: register!("cntv_ctl_el0"),
            })
        })();
        // Do not dispatch TimerDxe with our temporary compare value. Its period,
        // callback, original compare and enable/mask state remain unchanged.
        write(SGI + 0x180, GUARD);
        timer(2, saved_compare);
        write(SGI + 0x280, GUARD);
        if saved_pending != 0 {
            write(SGI + 0x200, saved_pending);
        }
        timer(saved_control, saved_compare);
        write(SGI + 0x180, u32::MAX);
        write(SGI + 0x100, enabled[0]);
        for (word, state) in enabled.iter().enumerate().take(self.words).skip(1) {
            write(GICD + 0x180 + word * 4, u32::MAX);
            write(GICD + 0x100 + word * 4, *state);
        }
        let restored = synchronize_gic().and_then(|()| {
            require(
                read(SGI + 0x100) == enabled[0]
                    && enabled
                        .iter()
                        .enumerate()
                        .take(self.words)
                        .skip(1)
                        .all(|(word, state)| read(GICD + 0x100 + word * 4) == *state),
                "interrupt-enable restoration readback mismatch",
            )
        });
        restore_irq(daif);
        if let Err(reason) = restored {
            log::error!("Interrupt-state restoration: {reason}");
        }
        result.and_then(|observation| restored.map(|()| observation))
    }

    pub fn restore(&mut self) -> TestResult {
        if self.restored {
            return Ok(());
        }
        write(GPIO + 0x410, 0);
        let mut result = Ok(());
        if self.registered {
            write(GICD + gpio_irq::DISABLE_OFFSET, IRQ_BIT);
            result =
                synchronize_gic().and_then(|()| set_gpio_irq_configuration(self.irq_configuration));
            unsafe {
                let status = ((*self.interface).register)(self.interface, IRQ, None);
                if status != Status::SUCCESS {
                    // Returning would unload a still-registered ISR.
                    log::error!(
                        "[FAIL] retention_cleanup - cannot unregister GPIO ISR: {status:?}"
                    );
                    runtime::reset(ResetType::SHUTDOWN, Status::ABORTED, None);
                }
            }
            self.registered = false;
            // Do not conceal a protocol unregistration/disable failure.
            if let Err(reason) = synchronize_gic().and_then(|()| {
                require(
                    !gpio_irq_enabled(),
                    "GPIO IRQ still enabled after unregister",
                )
            }) {
                log::error!("[FAIL] retention_cleanup - {reason}");
                runtime::reset(ResetType::SHUTDOWN, Status::ABORTED, None);
            }
            let configuration = gpio_irq::configuration(read(GICD + gpio_irq::CONFIG_OFFSET));
            log::info!(
                "RETENTION GICD restore readback: enabled={} configuration={:#x} expected={:#x}",
                gpio_irq_enabled(),
                configuration,
                self.irq_configuration,
            );
            result = result.and(require(
                configuration == self.irq_configuration,
                "GPIO trigger changed during unregistration",
            ));
        }
        for (offset, value) in GPIO_REGISTERS.into_iter().zip(self.gpio) {
            if offset != 0x410 {
                write(GPIO + offset, value);
            }
        }
        write(GPIO + 0x410, self.gpio[4]);
        PROTOCOL.store(ptr::null_mut(), Ordering::SeqCst);
        self.restored = true;
        result
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Err(reason) = self.restore() {
            log::error!("[FAIL] retention_cleanup - {reason}");
        }
    }
}
