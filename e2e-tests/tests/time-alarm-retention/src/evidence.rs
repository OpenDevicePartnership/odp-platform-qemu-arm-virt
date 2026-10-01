// SPDX-License-Identifier: MIT

#[derive(Clone, Copy)]
pub struct Observation {
    pub psci: i32,
    pub elapsed: u64,
    pub interrupt: u64,
    pub gpio: u32,
    pub masked: u32,
    pub timer_control: u64,
}

impl Observation {
    pub fn valid(&self, frequency: u64, wake: bool) -> bool {
        self.psci == 0
            && frequency != 0
            && if wake {
                self.interrupt == 39
                    && self.gpio & 2 != 0
                    && self.masked == 2
                    && self.elapsed >= frequency
                    && self.elapsed < 10 * frequency
                    && self.timer_control & 7 == 1
            } else {
                self.interrupt == 27
                    && self.gpio & 2 == 0
                    && self.masked == 0
                    && self.timer_control & 7 == 5
                    && (9 * frequency..=11 * frequency).contains(&self.elapsed)
            }
    }
}

#[cfg(test)]
mod tests {
    use super::Observation;

    const WAKE: Observation = Observation {
        psci: 0,
        elapsed: 500,
        interrupt: 39,
        gpio: 2,
        masked: 2,
        timer_control: 1,
    };
    const GUARD: Observation = Observation {
        psci: 0,
        elapsed: 1000,
        interrupt: 27,
        gpio: 0,
        masked: 0,
        timer_control: 5,
    };

    #[test]
    fn only_identified_gpio_wake_passes() {
        assert!(WAKE.valid(100, true));
        assert!(!WAKE.valid(100, false));
        for changed in [
            Observation { psci: -2, ..WAKE },
            Observation {
                interrupt: 27,
                ..WAKE
            },
            Observation {
                interrupt: 1023,
                ..WAKE
            },
            Observation { gpio: 0, ..WAKE },
            Observation { masked: 0, ..WAKE },
            Observation {
                timer_control: 5,
                ..WAKE
            },
        ] {
            assert!(!changed.valid(100, true));
        }
    }

    #[test]
    fn hid_does_not_fake_rtc() {
        assert!(!Observation {
            gpio: 1,
            masked: 1,
            ..WAKE
        }
        .valid(100, true));
        assert!(!Observation {
            gpio: 3,
            masked: 3,
            ..WAKE
        }
        .valid(100, true));
        assert!(Observation { gpio: 3, ..WAKE }.valid(100, true));
    }

    #[test]
    fn residency_and_guard_bounds_are_enforced() {
        for elapsed in [0, 99, 1000] {
            assert!(!Observation { elapsed, ..WAKE }.valid(100, true));
        }
        for elapsed in [100, 999] {
            assert!(Observation { elapsed, ..WAKE }.valid(100, true));
        }
        for elapsed in [899, 1101] {
            assert!(!Observation { elapsed, ..GUARD }.valid(100, false));
        }
        assert!(!WAKE.valid(0, true));
    }

    #[test]
    fn negative_cases_need_the_actual_guard() {
        assert!(GUARD.valid(100, false));
        assert!(!GUARD.valid(100, true));
        for changed in [
            Observation { psci: -1, ..GUARD },
            Observation {
                interrupt: 39,
                ..GUARD
            },
            Observation {
                interrupt: 1023,
                ..GUARD
            },
            Observation {
                timer_control: 1,
                ..GUARD
            },
            Observation { gpio: 2, ..GUARD },
            Observation { masked: 2, ..GUARD },
        ] {
            assert!(!changed.valid(100, false));
        }
    }
}
