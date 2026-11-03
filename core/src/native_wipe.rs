//! Native heap wiping (`native/wipe.cpp`). Rust's own heap is covered by
//! `alloc::WipingAllocator`; this covers whisper.cpp/ggml:
//!
//! - replacement global C++ `operator new`/`delete` (all forms): deletes zero
//!   `malloc_size(p)` bytes with `memset_s` before `free`;
//! - whisper.cpp/ggml sources are compiled with `wipe_free.h` force-included,
//!   so their `free`/`realloc` calls zero the block first. On iOS that covers
//!   ggml's CPU buffers and Metal shared (unified-memory) buffers, which ggml
//!   allocates with `posix_memalign` and releases with `free`.

extern "C" {
    fn recordless_native_wipe_installed() -> i32;
}

/// Called once from `Session::new`; the reference keeps the native object in
/// every image the core is linked into.
pub(crate) fn installed() -> bool {
    unsafe { recordless_native_wipe_installed() == 1 }
}

#[cfg(test)]
mod tests {
    extern "C" {
        fn recordless_wipe_probe_string() -> i32;
        fn recordless_wipe_probe_vector() -> i32;
        fn recordless_wipe_probe_aligned() -> i32;
        fn recordless_wipe_probe_c_free() -> i32;
        fn recordless_wipe_probe_c_realloc() -> i32;
        fn recordless_wipe_probe_system_library() -> i32;
    }

    // 1 = the block was zeroed before free; -1 = freed unwiped; 0 = never
    // reached the replacement (it is not linked in, or was bypassed).

    #[test]
    fn cpp_string_buffer_is_zeroed_before_free() {
        assert!(super::installed());
        assert_eq!(unsafe { recordless_wipe_probe_string() }, 1);
    }

    #[test]
    fn cpp_vector_buffer_is_zeroed_before_free() {
        assert_eq!(unsafe { recordless_wipe_probe_vector() }, 1);
    }

    #[test]
    fn cpp_aligned_delete_is_zeroed_before_free() {
        assert_eq!(unsafe { recordless_wipe_probe_aligned() }, 1);
    }

    #[test]
    fn c_free_used_by_whisper_and_ggml_zeroes() {
        assert_eq!(unsafe { recordless_wipe_probe_c_free() }, 1);
    }

    #[test]
    fn c_realloc_used_by_whisper_and_ggml_zeroes_the_old_block() {
        assert_eq!(unsafe { recordless_wipe_probe_c_realloc() }, 1);
    }

    /// Documents (and pins) whether deletes made inside libc++.dylib reach the
    /// replacement through dyld's weak-definition coalescing. On macOS/iOS
    /// the replaceable operators are weak in libc++abi, so they do: system
    /// libraries in this process also wipe on delete.
    #[test]
    fn system_library_deletes_reach_the_replacement() {
        assert_eq!(unsafe { recordless_wipe_probe_system_library() }, 1);
    }
}
