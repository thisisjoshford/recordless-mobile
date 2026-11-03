//! Process memory via `task_info(TASK_VM_INFO)` — the same `phys_footprint`
//! number the iOS jetsam limit is enforced against.

#[cfg(target_vendor = "apple")]
mod imp {
    use std::mem::size_of;

    const TASK_VM_INFO: u32 = 22;

    /// `struct task_vm_info` from <mach/task_info.h> through rev3's
    /// `ledger_phys_footprint_peak` (packed to 4 like the C header). The
    /// kernel fills as many 32-bit words as we pass and reports the count.
    #[repr(C, packed(4))]
    #[derive(Default, Clone, Copy)]
    struct TaskVmInfo {
        virtual_size: u64,
        region_count: i32,
        page_size: i32,
        resident_size: u64,
        resident_size_peak: u64,
        device: u64,
        device_peak: u64,
        internal: u64,
        internal_peak: u64,
        external: u64,
        external_peak: u64,
        reusable: u64,
        reusable_peak: u64,
        purgeable_volatile_pmap: u64,
        purgeable_volatile_resident: u64,
        purgeable_volatile_virtual: u64,
        compressed: u64,
        compressed_peak: u64,
        compressed_lifetime: u64,
        // rev1
        phys_footprint: u64,
        // rev2
        min_address: u64,
        max_address: u64,
        // rev3 (first field)
        ledger_phys_footprint_peak: i64,
    }

    const WORDS_REV1: u32 = (std::mem::offset_of!(TaskVmInfo, min_address) / 4) as u32;
    const WORDS_PEAK: u32 = (size_of::<TaskVmInfo>() / 4) as u32;

    extern "C" {
        static mach_task_self_: u32;
        fn task_info(task: u32, flavor: u32, info: *mut i32, count: *mut u32) -> i32;
    }

    fn query() -> Option<(TaskVmInfo, u32)> {
        let mut info = TaskVmInfo::default();
        let mut count = WORDS_PEAK;
        // SAFETY: `info` is a writable buffer of `count` 32-bit words.
        let kr = unsafe {
            task_info(mach_task_self_, TASK_VM_INFO, (&mut info as *mut TaskVmInfo).cast(), &mut count)
        };
        (kr == 0).then_some((info, count))
    }

    pub fn phys_footprint_bytes() -> u64 {
        match query() {
            Some((info, count)) if count >= WORDS_REV1 => info.phys_footprint,
            Some((info, _)) => info.resident_size,
            None => 0,
        }
    }

    pub fn peak_footprint_bytes() -> u64 {
        match query() {
            Some((info, count)) if count >= WORDS_PEAK && info.ledger_phys_footprint_peak > 0 => {
                info.ledger_phys_footprint_peak as u64
            }
            Some((info, _)) => info.resident_size_peak,
            None => 0,
        }
    }
}

#[cfg(not(target_vendor = "apple"))]
mod imp {
    pub fn phys_footprint_bytes() -> u64 {
        0
    }
    pub fn peak_footprint_bytes() -> u64 {
        0
    }
}

pub use imp::{peak_footprint_bytes, phys_footprint_bytes};

#[cfg(all(test, target_vendor = "apple"))]
mod tests {
    use super::*;

    #[test]
    fn footprint_is_plausible_and_peak_covers_it() {
        let before = phys_footprint_bytes();
        assert!(before > 1 << 20, "footprint {before}");
        let big = vec![1u8; 64 << 20];
        std::hint::black_box(&big);
        let during = phys_footprint_bytes();
        assert!(during >= before + (48 << 20), "{before} -> {during}");
        assert!(peak_footprint_bytes() >= during);
    }
}
