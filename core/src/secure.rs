//! Locked, zeroed-on-drop memory for transcript text and secrets.
//! Port of desktop `confidential-security` (`LockedBytes`, `disable_process_dumps`).
//! These do not defend against a compromised kernel.

use std::mem::MaybeUninit;
use std::ptr;
use zeroize::Zeroize;

/// Separate page-aligned storage, `mlock`ed before sensitive bytes are copied in.
/// No Debug/Serialize implementation: secrets must be accessed deliberately.
pub struct LockedBytes {
    ptr: *mut u8,
    len: usize,
    allocated: usize,
}

// SAFETY: the mapping is owned exclusively by this value; access is via &self/&mut self.
unsafe impl Send for LockedBytes {}
unsafe impl Sync for LockedBytes {}

impl LockedBytes {
    /// Fails (rather than silently degrading) when the page cannot be locked.
    pub fn new(bytes: &[u8]) -> Result<Self, String> {
        // SAFETY: plain mmap/mlock of a private anonymous mapping we own.
        unsafe {
            let page = libc::sysconf(libc::_SC_PAGESIZE) as usize;
            if page == 0 || page > 1024 * 1024 {
                return Err("Cannot determine memory page size".into());
            }
            let allocated = bytes
                .len()
                .max(1)
                .checked_add(page - 1)
                .ok_or("Secret too large")?
                / page
                * page;
            let raw = libc::mmap(
                ptr::null_mut(),
                allocated,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANON,
                -1,
                0,
            );
            if raw == libc::MAP_FAILED {
                return Err("Cannot allocate protected memory".into());
            }
            if libc::mlock(raw, allocated) != 0 {
                libc::munmap(raw, allocated);
                return Err(
                    "Cannot lock sensitive memory (mlock failed); transcription is unavailable".into(),
                );
            }
            ptr::copy_nonoverlapping(bytes.as_ptr(), raw.cast(), bytes.len());
            Ok(Self { ptr: raw.cast(), len: bytes.len(), allocated })
        }
    }

    pub fn as_slice(&self) -> &[u8] {
        // SAFETY: the first `len` bytes were initialised in `new`.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }

    /// Overwrite the whole locked region with zeros. Called by `Drop`.
    fn wipe(&mut self) {
        // SAFETY: bytes past `len` were never written, so the region is viewed
        // as possibly-uninitialised; zeroize writes volatilely without reading.
        unsafe {
            std::slice::from_raw_parts_mut(self.ptr.cast::<MaybeUninit<u8>>(), self.allocated)
                .zeroize();
        }
    }
}

impl Drop for LockedBytes {
    fn drop(&mut self) {
        self.wipe();
        // SAFETY: unmapping the region mapped in `new`.
        unsafe {
            libc::munlock(self.ptr.cast(), self.allocated);
            libc::munmap(self.ptr.cast(), self.allocated);
        }
    }
}

/// Overwrite a string's bytes with zeros, then clear it (capacity is kept).
pub fn wipe_string(s: &mut String) {
    // SAFETY: zero bytes keep the buffer valid UTF-8 and we clear right after.
    unsafe { s.as_bytes_mut().zeroize() };
    s.clear();
}

/// Establish before capture. Failure must prevent processing.
pub fn disable_process_dumps() -> Result<(), String> {
    let limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: setrlimit with a valid struct.
    if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) } != 0 {
        return Err("Cannot disable process core dumps".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locked_memory_round_trips() {
        let secret = LockedBytes::new(b"protected-test-marker").unwrap();
        assert_eq!(secret.as_slice(), b"protected-test-marker");
    }

    #[test]
    fn locked_memory_is_zeroed_by_wipe() {
        let mut secret = LockedBytes::new(b"CANARY-locked-bytes").unwrap();
        secret.wipe();
        assert!(secret.as_slice().iter().all(|b| *b == 0));
        // Whole page, not just `len`.
        let page = unsafe { std::slice::from_raw_parts(secret.ptr, secret.allocated) };
        assert!(page.iter().all(|b| *b == 0));
    }

    #[test]
    fn wipe_string_zeroes_buffer_before_clear() {
        let mut s = String::from("CANARY-secret-text");
        let len = s.len();
        let p = s.as_ptr();
        wipe_string(&mut s);
        assert!(s.is_empty());
        // The allocation is still owned by `s` (clear keeps capacity).
        let bytes = unsafe { std::slice::from_raw_parts(p, len) };
        assert!(bytes.iter().all(|b| *b == 0));
    }
}
