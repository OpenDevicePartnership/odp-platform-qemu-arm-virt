// SPDX-License-Identifier: MIT

pub const IRQ: usize = 39;
pub const BIT: u32 = 1 << (IRQ % 32);
pub const ENABLE_OFFSET: usize = 0x100 + (IRQ / 32) * 4;
pub const DISABLE_OFFSET: usize = 0x180 + (IRQ / 32) * 4;
pub const CONFIG_OFFSET: usize = 0xc00 + (IRQ / 16) * 4;
const CONFIG_MASK: u32 = 3 << ((IRQ % 16) * 2);

pub fn enabled(isenabler: u32) -> bool {
    isenabler & BIT != 0
}

pub fn configuration(icfgr: u32) -> u32 {
    icfgr & CONFIG_MASK
}

pub fn with_configuration(icfgr: u32, saved: u32) -> u32 {
    (icfgr & !CONFIG_MASK) | configuration(saved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn intid39_uses_distributor_word1_and_configuration_word2() {
        assert_eq!(IRQ, 39);
        assert_eq!(BIT, 0x80);
        assert_eq!(ENABLE_OFFSET, 0x104);
        assert_eq!(DISABLE_OFFSET, 0x184);
        assert_eq!(CONFIG_OFFSET, 0xc08);
        assert_eq!(CONFIG_MASK, 0xc000);
    }

    #[test]
    fn admission_checks_only_intid39_enable_bit() {
        assert!(!enabled(0));
        assert!(!enabled((1 << 6) | (1 << 8)));
        assert!(enabled(0x80));
        assert!(enabled(u32::MAX));
    }

    #[test]
    fn admission_ignores_the_next_spi_word() {
        let mut isenabler = [0; 3];
        let index = (ENABLE_OFFSET - 0x100) / 4;
        isenabler[1] = BIT;
        assert!(enabled(isenabler[index]));
        isenabler[1] = 0;
        isenabler[2] = BIT;
        assert!(!enabled(isenabler[index]));
    }

    #[test]
    fn level_zero_restores_zero_not_edge() {
        let saved = configuration(0);
        assert_eq!(saved, 0);
        assert_eq!(configuration(1 << 7), 0);
        assert_eq!(with_configuration(0, saved), 0);
        assert_eq!(with_configuration(0x8000, saved), 0);
    }

    #[test]
    fn edge_configuration_round_trips_through_level_mode() {
        let original = 0xaaaa_aaaa;
        let saved = configuration(original);
        assert_eq!(saved, 0x8000);
        let level = with_configuration(original, 0);
        assert_eq!(configuration(level), 0);
        assert_eq!(with_configuration(level, saved), original);
    }

    #[test]
    fn restoration_preserves_other_interrupt_configuration() {
        let current = 0xaaaa_aaaa;
        let restored = with_configuration(current, 0);
        assert_eq!(restored & !CONFIG_MASK, current & !CONFIG_MASK);
        assert_eq!(configuration(restored), 0);
    }
}
