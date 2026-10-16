// SPDX-License-Identifier: MIT

pub const IRQ: usize = 39;
pub const IRQ_BIT: u32 = 1 << (IRQ % 32);
pub const ENABLE_OFFSET: usize = 0x100 + (IRQ / 32) * 4;
pub const CONFIG_OFFSET: usize = 0xc00 + (IRQ / 16) * 4;
pub const CONFIG_MASK: u32 = 3 << ((IRQ % 16) * 2);
pub const PIN: u32 = 2;

pub fn with_configuration(current: u32, saved: u32) -> u32 {
    (current & !CONFIG_MASK) | (saved & CONFIG_MASK)
}

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
            && self.interrupt == if wake { IRQ as u64 } else { 27 }
            && self.masked == if wake { PIN } else { 0 }
            && self.gpio & PIN == self.masked
            && self.timer_control & 7 == if wake { 1 } else { 5 }
            && if wake {
                (frequency..10 * frequency).contains(&self.elapsed)
            } else {
                (9 * frequency..=11 * frequency).contains(&self.elapsed)
            }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RTC_WAKE: Observation = Observation {
        psci: 0,
        elapsed: 500,
        interrupt: 39,
        gpio: 2,
        masked: 2,
        timer_control: 1,
    };

    #[test]
    fn hid_and_guard_cannot_impersonate_rtc_wake() {
        let mut observation = RTC_WAKE;
        observation.gpio = 3;
        assert!(observation.valid(100, true));
        for pins in [1, 3] {
            observation.gpio = pins;
            observation.masked = pins;
            assert!(!observation.valid(100, true));
        }
        observation = RTC_WAKE;
        observation.interrupt = 27;
        assert!(!observation.valid(100, true));
        observation = RTC_WAKE;
        observation.timer_control = 5;
        assert!(!observation.valid(100, true));
    }

    #[test]
    fn residency_edges_distinguish_wake_from_guard_timeout() {
        let mut observation = RTC_WAKE;
        for (elapsed, accepted) in [(99, false), (100, true), (999, true), (1000, false)] {
            observation.elapsed = elapsed;
            assert_eq!(
                observation.valid(100, true),
                accepted,
                "wake ticks={elapsed}"
            );
        }
        observation.interrupt = 27;
        observation.gpio = 0;
        observation.masked = 0;
        observation.timer_control = 5;
        for (elapsed, accepted) in [(899, false), (900, true), (1100, true), (1101, false)] {
            observation.elapsed = elapsed;
            assert_eq!(
                observation.valid(100, false),
                accepted,
                "guard ticks={elapsed}"
            );
        }
        observation.elapsed = 0;
        assert!(!observation.valid(0, false));
    }

    #[test]
    fn ownership_reads_spi39_not_the_next_word_or_neighbor() {
        let mut enabled = [0, 0x100, 0x80];
        let word = (ENABLE_OFFSET - 0x100) / 4;
        assert_eq!(enabled[word] & IRQ_BIT, 0);
        enabled[1] = 0x80;
        enabled[2] = 0;
        assert_ne!(enabled[word] & IRQ_BIT, 0);
    }

    #[test]
    fn level_and_edge_restore_without_changing_neighbors() {
        let word = (CONFIG_OFFSET - 0xc00) / 4;
        for original in [0xffff_3fff, 0xffff_bfff] {
            let mut configuration = [0, 0, original, 0];
            let saved = configuration[word] & CONFIG_MASK;
            configuration[word] = with_configuration(configuration[word], 0);
            assert_eq!(configuration[2], 0xffff_3fff);
            assert_eq!(with_configuration(configuration[word], saved), original);
        }
    }
}
