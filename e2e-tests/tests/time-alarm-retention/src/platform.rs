// SPDX-License-Identifier: MIT

use core::{
    arch::asm,
    ffi::c_void,
    ptr,
    sync::atomic::{AtomicBool, AtomicPtr, AtomicU32, Ordering},
};
use uefi::{
    boot::{self, OpenProtocolAttributes, OpenProtocolParams, ScopedProtocol},
    proto::unsafe_protocol,
    runtime::{self, ResetType},
    Status,
};

use crate::{
    interrupt::{
        with_configuration, Observation, CONFIG_MASK, CONFIG_OFFSET, ENABLE_OFFSET, IRQ, IRQ_BIT,
        PIN,
    },
    require, TestResult,
};

// QEMU virt memory map (hw/arm/virt.c), also described by ArmPlatformLibQemu.c.
const GPIO: usize = 0x0903_0000;
const GICD: usize = 0x0800_0000;
const GICR: usize = 0x080a_0000;
// GICv3 redistributors place the SGI/PPI frame 64 KiB after the control frame.
const SGI: usize = GICR + 0x1_0000;

// Arm PL061 TRM (DDI 0190), mirrored by QEMU's hw/odp/pl061.c.
// GPIODATA address bits [9:2] select which pins are read or written.
const GPIO_DATA_PIN: usize = (PIN as usize) << 2;
const GPIO_DATA_ALL: usize = 0xff << 2;
const GPIO_DIR: usize = 0x400;
const GPIO_IS: usize = 0x404; // Interrupt sense: 1 = level-sensitive.
const GPIO_IBE: usize = 0x408; // Both-edge interrupt selection.
const GPIO_IEV: usize = 0x40c; // Interrupt polarity: 1 = high/rising.
const GPIO_IM: usize = 0x410; // Interrupt mask: 1 = enabled.
const GPIO_RIS: usize = 0x414;
const GPIO_MIS: usize = 0x418;
const GPIO_IC: usize = 0x41c;
const GPIO_AFSEL: usize = 0x420;
// Restore the interrupt mask last, after direction/sense/polarity.
const GPIO_REGISTERS: [usize; 6] = [GPIO_DIR, GPIO_IS, GPIO_IBE, GPIO_IEV, GPIO_AFSEL, GPIO_IM];

// Arm GICv3 register map (IHI 0069); offsets shared by GICD and the GICR SGI/PPI frame.
const GIC_ISENABLER: usize = 0x100;
const GIC_ICENABLER: usize = 0x180;
const GIC_ISPENDR: usize = 0x200;
const GIC_ICPENDR: usize = 0x280;
const GIC_IPRIORITYR: usize = 0x400;
const GICD_TYPER: usize = 0x4;
const GICR_TYPER: usize = 0x8;
const GICD_IROUTER: usize = 0x6000; // Indexed by architectural INTID, not SPI index.
const GICD_ICENABLER1: usize = 0x184;
const GICD_ISPENDR1: usize = 0x204;
const GICD_ICPENDR1: usize = 0x284;
const GICD_ISACTIVER1: usize = 0x304;
const GICD_CTLR_RWP: u32 = 1 << 31;
const GICR_CTLR_RWP: u32 = 1 << 3;
const GICR_CTLR_ENABLE_LPIS: u32 = 1;
const GICD_CTLR_ARE_NS: u32 = 1 << 4; // Non-secure view of GICD_CTLR.
const GICD_TYPER_ITLINES_MASK: u32 = 0x1f;
const GIC_MAX_ENABLE_WORDS: usize = 32; // ITLinesNumber is a five-bit field, plus one.
const GIC_LEVEL_TRIGGERED: u32 = 0;
const GIC_IDLE_PRIORITY: u64 = 0xff;
const GIC_SPURIOUS_INTID: u64 = 1023;
const GIC_GROUP1_ENABLE: u64 = 1;
const GUARD_INTID: usize = 27; // QEMU virt virtual timer PPI used by TimerDxe.
const GUARD: u32 = 1 << GUARD_INTID;

// AArch64 system-register fields (TF-A include/arch/aarch64/arch.h).
const CURRENT_EL1: u64 = 1 << 2;
const CURRENT_EL2: u64 = 2 << 2;
const DAIF_IRQ_MASK: u64 = 1 << 7;
const DAIFSET_IRQ: u64 = 1 << 1;
const MPIDR_AFFINITY_MASK: u64 = 0xff00ffffff;
const CNTV_CTL_ENABLE: u64 = 1;
const CNTV_CTL_IMASK: u64 = 1 << 1;
const CNTV_CTL_WRITABLE: u64 = CNTV_CTL_ENABLE | CNTV_CTL_IMASK;

// PSCI IDs: TF-A include/lib/psci/psci.h; state 1: plat/qemu/common/qemu_pm.c.
const PSCI_FEATURES: u64 = 0x8400_000a;
const CPU_SUSPEND64: u64 = 0xc400_0001;
const QEMU_CPU_RETENTION_STATE: u64 = 1;

// Fixture timing policy, not hardware encodings.
const GIC_WRITE_TIMEOUT_DIVISOR: u64 = 10; // 100 ms.
const GUARD_SECONDS: u64 = 10;
const MIN_GUARD_REMAINING_SECONDS: u64 = 9;

type Handler = unsafe extern "efiapi" fn(usize, *mut c_void);
type SourceOperation = unsafe extern "efiapi" fn(*mut HardwareInterrupt, usize) -> Status;

// Public HardwareInterrupt2 ABI; Patina's private trailing fields are not ours.
#[repr(C)]
#[unsafe_protocol("32898322-2da1-474a-baaa-f3f7cf569470")]
struct HardwareInterrupt {
    register: unsafe extern "efiapi" fn(*mut Self, usize, Option<Handler>) -> Status,
    enable: SourceOperation,
    disable: SourceOperation,
    state: unsafe extern "efiapi" fn(*mut Self, usize, *mut bool) -> Status,
    eoi: SourceOperation,
    get_trigger: unsafe extern "efiapi" fn(*mut Self, usize, *mut u32) -> Status,
    set_trigger: unsafe extern "efiapi" fn(*mut Self, usize, u32) -> Status,
}

fn check(status: Status, operation: &'static str) -> TestResult {
    if status != Status::SUCCESS {
        log::error!("{operation}: {status:?}");
    }
    require(status == Status::SUCCESS, operation)
}

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
        asm!("msr daifset, #{irq}", "isb", irq = const DAIFSET_IRQ, options(nostack));
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
            masked = in(reg) CNTV_CTL_IMASK, compare = in(reg) compare, control = in(reg) control,
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
    let deadline = counter() + frequency() / GIC_WRITE_TIMEOUT_DIVISOR;
    unsafe {
        asm!("dsb sy", options(nostack));
    }
    while read(GICD) & GICD_CTLR_RWP != 0 || read(GICR) & GICR_CTLR_RWP != 0 {
        require(counter() < deadline, "GIC register write did not complete")?;
    }
    unsafe {
        asm!("dsb sy", "isb", options(nostack));
    }
    Ok(())
}

fn gpio_irq_enabled() -> bool {
    read(GICD + ENABLE_OFFSET) & IRQ_BIT != 0
}

fn set_gpio_irq_configuration(configuration: u32) -> TestResult {
    require(
        !gpio_irq_enabled(),
        "GPIO IRQ must be disabled before changing its trigger",
    )?;
    let address = GICD + CONFIG_OFFSET;
    let expected = with_configuration(read(address), configuration);
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
    ISR_PIN.store(read(GPIO + GPIO_MIS), Ordering::SeqCst);
    write(GPIO + GPIO_IM, 0);
    unsafe {
        asm!("dsb sy", options(nostack));
    }
    let protocol = PROTOCOL.load(Ordering::SeqCst);
    // Patina acknowledges on dispatch, but a registered handler owns its EOI.
    let status = unsafe { ((*protocol).eoi)(protocol, source) };
    ISR_ERROR.store(source != IRQ || status != Status::SUCCESS, Ordering::SeqCst);
}

pub struct Fixture {
    protocol: ScopedProtocol<HardwareInterrupt>,
    gpio: [u32; 6],
    irq_configuration: u32,
    words: usize,
    registered: bool,
    restored: bool,
}

impl Fixture {
    pub fn new() -> TestResult<Self> {
        let current_el = register!("CurrentEL");
        log::info!("RETENTION CurrentEL={}", current_el >> 2);
        require(
            matches!(current_el, CURRENT_EL1 | CURRENT_EL2),
            "requires NS EL1 or EL2",
        )?;
        require(
            register!("daif") & DAIF_IRQ_MASK == 0,
            "UEFI IRQ dispatch is disabled",
        )?;
        let mpidr = register!("mpidr_el1");
        log::info!("RETENTION MPIDR={mpidr:#x}");
        require(
            mpidr & MPIDR_AFFINITY_MASK == 0,
            "fixture requires QEMU boot CPU",
        )?;
        require(frequency() != 0, "architectural counter frequency is zero")?;
        require(
            smc(PSCI_FEATURES, CPU_SUSPEND64) >= 0,
            "PSCI CPU_SUSPEND64 unsupported",
        )?;
        // GICR_TYPER affinity occupies bits [63:32]; each IROUTER entry is 64 bits.
        let redistributor_affinity = read64(GICR + GICR_TYPER) >> 32;
        let gpio_route = read64(GICD + GICD_IROUTER + IRQ * size_of::<u64>());
        log::info!(
            "RETENTION GICR={GICR:#x} affinity={redistributor_affinity:#x} GPIO_IROUTER={gpio_route:#x}"
        );
        require(
            redistributor_affinity == 0,
            "redistributor does not target boot CPU",
        )?;
        require(
            read(GICR) & GICR_CTLR_ENABLE_LPIS == 0,
            "LPI isolation is not supported by this fixture",
        )?;
        require(
            read(GICD) & GICD_CTLR_ARE_NS != 0,
            "GIC non-secure affinity routing is disabled",
        )?;
        require(gpio_route == 0, "GPIO IRQ routes away from boot CPU")?;
        let priority_mask = register!("icc_pmr_el1");
        // IPRIORITYR packs four eight-bit priorities into each 32-bit word.
        let gpio_priority = (read(GICD + GIC_IPRIORITYR + (IRQ & !3)) >> ((IRQ & 3) * 8)) & 0xff;
        let guard_priority =
            read(SGI + GIC_IPRIORITYR + (GUARD_INTID & !3)) >> ((GUARD_INTID & 3) * 8);
        require(
            u64::from(gpio_priority) < priority_mask
                && u64::from(guard_priority) < priority_mask
                && register!("icc_igrpen1_el1") & GIC_GROUP1_ENABLE != 0
                && register!("icc_rpr_el1") == GIC_IDLE_PRIORITY,
            "GIC priorities/group delivery would block the wake or guard",
        )?;
        require(
            read(GICD + GICD_ISPENDR1) & IRQ_BIT == 0
                && read(GICD + GICD_ISACTIVER1) & IRQ_BIT == 0,
            "GPIO IRQ is already pending or active",
        )?;
        let handle = boot::get_handle_for_protocol::<HardwareInterrupt>()
            .map_err(|_| "HardwareInterrupt2 protocol unavailable")?;
        // This shared firmware protocol stays installed throughout boot services.
        let protocol = unsafe {
            boot::open_protocol(
                OpenProtocolParams {
                    handle,
                    agent: boot::image_handle(),
                    controller: None,
                },
                OpenProtocolAttributes::GetProtocol,
            )
        }
        .map_err(|_| "cannot open HardwareInterrupt2 protocol")?;
        // Patina 22.1's SPI getters misindex saved context and misdecode ICFGR.
        let enabled_word = read(GICD + ENABLE_OFFSET);
        let configuration_word = read(GICD + CONFIG_OFFSET);
        log::warn!("RETENTION bypassing known-bad Patina 22.1 SPI state/trigger getters");
        log::info!(
            "RETENTION HardwareInterrupt2 available; GICD INTID39 ISENABLER1={enabled_word:#x} ICFGR2={configuration_word:#x}"
        );
        require(
            enabled_word & IRQ_BIT == 0,
            "GPIO interrupt already enabled; refusing to take ownership",
        )?;
        require(
            read(GPIO + GPIO_DATA_PIN) == 0,
            "GPIO1 was asserted before fixture setup",
        )?;
        let mut fixture = Self {
            protocol,
            gpio: GPIO_REGISTERS.map(|offset| read(GPIO + offset)),
            irq_configuration: configuration_word & CONFIG_MASK,
            words: ((read(GICD + GICD_TYPER) & GICD_TYPER_ITLINES_MASK) + 1) as usize,
            registered: false,
            restored: false,
        };
        write(GPIO + GPIO_IM, 0);
        unsafe {
            asm!("dsb sy", options(nostack));
        }
        let interface = ptr::from_mut(&mut *fixture.protocol);
        PROTOCOL.store(interface, Ordering::SeqCst);
        unsafe {
            check(
                ((*interface).register)(interface, IRQ, Some(gpio_interrupt)),
                "claim GPIO IRQ (must be unowned)",
            )?;
        }
        fixture.registered = true;
        // Registration enables the source; ICFGR changes require it disabled.
        write(GICD + GICD_ICENABLER1, IRQ_BIT);
        synchronize_gic()?;
        set_gpio_irq_configuration(GIC_LEVEL_TRIGGERED)?;
        write(GPIO + GPIO_DIR, fixture.gpio[0] & !PIN);
        write(GPIO + GPIO_IS, fixture.gpio[1] | PIN);
        write(GPIO + GPIO_IBE, fixture.gpio[2] & !PIN);
        write(GPIO + GPIO_IEV, fixture.gpio[3] | PIN);
        write(GPIO + GPIO_AFSEL, fixture.gpio[4] & !PIN);
        fixture.clear_pending()?;
        write(GICD + ENABLE_OFFSET, IRQ_BIT);
        synchronize_gic()?;
        require(
            gpio_irq_enabled(),
            "GPIO IRQ did not enable after configuration",
        )?;
        Ok(fixture)
    }

    pub fn pin_low(&self) -> bool {
        read(GPIO + GPIO_DATA_PIN) == 0
    }

    pub fn clear_pending(&self) -> TestResult {
        require(
            self.pin_low(),
            "cannot clear GPIO pending state while pin1 is high",
        )?;
        write(GPIO + GPIO_IM, 0);
        write(GPIO + GPIO_IC, PIN);
        write(GICD + GICD_ICPENDR1, IRQ_BIT);
        synchronize_gic()?;
        require(
            read(GPIO + GPIO_RIS) & PIN == 0 && read(GICD + GICD_ISPENDR1) & IRQ_BIT == 0,
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
        let saved_control = register!("cntv_ctl_el0") & CNTV_CTL_WRITABLE;
        let saved_compare = register!("cntv_cval_el0");
        let saved_pending = read(SGI + GIC_ISPENDR) & GUARD;
        let mut enabled = [0; GIC_MAX_ENABLE_WORDS];
        let banks =
            core::iter::once(SGI).chain((1..self.words).map(|word| GICD + word * size_of::<u32>()));
        for (bank, state) in banks.clone().zip(&mut enabled) {
            *state = read(bank + GIC_ISENABLER);
            // Non-secure accesses leave secure interrupt enables untouched.
            write(bank + GIC_ICENABLER, u32::MAX);
        }
        let result = (|| {
            synchronize_gic()?;
            timer(CNTV_CTL_IMASK, saved_compare);
            write(SGI + GIC_ICPENDR, GUARD);
            let deadline = counter() + GUARD_SECONDS * frequency();
            timer(CNTV_CTL_ENABLE, deadline);
            write(GPIO + GPIO_IM, PIN);
            write(SGI + GIC_ISENABLER, GUARD);
            write(GICD + ENABLE_OFFSET, IRQ_BIT);
            synchronize_gic()?;
            require(
                register!("cntv_ctl_el0") & CNTV_CTL_WRITABLE == CNTV_CTL_ENABLE
                    && register!("cntv_cval_el0") == deadline,
                "guard timer did not arm",
            )?;
            require(
                read(GPIO + GPIO_IM) == PIN
                    && read(SGI + GIC_ISENABLER) == GUARD
                    && (1..self.words).all(|word| {
                        read(GICD + GIC_ISENABLER + word * size_of::<u32>())
                            == if word == IRQ / 32 { IRQ_BIT } else { 0 }
                    }),
                "unrelated non-secure IRQs were not isolated",
            )?;
            require(
                self.pin_low()
                    && read(GPIO + GPIO_RIS) & PIN == 0
                    && read(GICD + GICD_ISPENDR1) & IRQ_BIT == 0,
                "GPIO1 asserted before CPU standby",
            )?;
            require(
                register!("icc_hppir1_el1") == GIC_SPURIOUS_INTID,
                "an IRQ was pending before standby",
            )?;
            let start = counter();
            require(
                start - sampled < frequency(),
                "EC remaining-time sample became stale",
            )?;
            require(
                deadline - start >= MIN_GUARD_REMAINING_SECONDS * frequency(),
                "guard deadline too close",
            )?;
            let psci = smc(CPU_SUSPEND64, QEMU_CPU_RETENTION_STATE);
            let elapsed = counter() - start;
            Ok(Observation {
                psci,
                elapsed,
                interrupt: register!("icc_hppir1_el1"),
                gpio: read(GPIO + GPIO_DATA_ALL),
                masked: read(GPIO + GPIO_MIS),
                timer_control: register!("cntv_ctl_el0"),
            })
        })();
        // Do not dispatch TimerDxe with our temporary compare value. Its period,
        // callback, original compare and enable/mask state remain unchanged.
        write(SGI + GIC_ICENABLER, GUARD);
        timer(CNTV_CTL_IMASK, saved_compare);
        write(SGI + GIC_ICPENDR, GUARD);
        if saved_pending != 0 {
            write(SGI + GIC_ISPENDR, saved_pending);
        }
        timer(saved_control, saved_compare);
        for (bank, state) in banks.clone().zip(enabled) {
            write(bank + GIC_ICENABLER, u32::MAX);
            write(bank + GIC_ISENABLER, state);
        }
        let restored = synchronize_gic().and_then(|()| {
            require(
                banks
                    .zip(enabled)
                    .all(|(bank, state)| read(bank + GIC_ISENABLER) == state),
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
        write(GPIO + GPIO_IM, 0);
        let mut result = Ok(());
        if self.registered {
            write(GICD + GICD_ICENABLER1, IRQ_BIT);
            result =
                synchronize_gic().and_then(|()| set_gpio_irq_configuration(self.irq_configuration));
            let interface = ptr::from_mut(&mut *self.protocol);
            let unregistered = check(
                unsafe { ((*interface).register)(interface, IRQ, None) },
                "cannot unregister GPIO ISR",
            )
            .and_then(|()| synchronize_gic())
            .and_then(|()| {
                require(
                    !gpio_irq_enabled(),
                    "GPIO IRQ still enabled after unregister",
                )
            });
            if let Err(reason) = unregistered {
                // Returning could unload a still-registered ISR.
                log::error!("[FAIL] retention_cleanup - {reason}");
                runtime::reset(ResetType::SHUTDOWN, Status::ABORTED, None);
            }
            self.registered = false;
            let configuration = read(GICD + CONFIG_OFFSET) & CONFIG_MASK;
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
            write(GPIO + offset, value);
        }
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
