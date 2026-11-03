//! Port of desktop `confidential_security::WipingAllocator`.
use std::alloc::{GlobalAlloc, Layout, System};
use std::mem::MaybeUninit;
use std::ptr;
use zeroize::Zeroize;

/// Wipe every Rust heap allocation before returning it to the allocator.
pub struct WipingAllocator;

unsafe impl GlobalAlloc for WipingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        System.alloc(layout)
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        System.alloc_zeroed(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // A freed block may hold uninitialised bytes, so view it as MaybeUninit.
        std::slice::from_raw_parts_mut(ptr.cast::<MaybeUninit<u8>>(), layout.size()).zeroize();
        System.dealloc(ptr, layout);
    }
    unsafe fn realloc(&self, old: *mut u8, layout: Layout, size: usize) -> *mut u8 {
        let Ok(new_layout) = Layout::from_size_align(size, layout.align()) else {
            return ptr::null_mut();
        };
        let new = System.alloc(new_layout);
        if !new.is_null() {
            ptr::copy_nonoverlapping(old, new, size.min(layout.size()));
            self.dealloc(old, layout);
        }
        new
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reallocation_preserves_live_bytes() {
        unsafe {
            let layout = Layout::from_size_align(32, 8).unwrap();
            let p = WipingAllocator.alloc(layout);
            assert!(!p.is_null());
            ptr::write_bytes(p, 0x5a, 32);
            let q = WipingAllocator.realloc(p, layout, 128);
            assert!(!q.is_null());
            assert_eq!(std::slice::from_raw_parts(q, 32), &[0x5a; 32]);
            WipingAllocator.dealloc(q, Layout::from_size_align(128, 8).unwrap());
        }
    }
}
