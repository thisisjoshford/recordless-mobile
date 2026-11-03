//! Recordless on-device core (phase-0 spike). FFI contract: docs/core-ffi.md.
//!
//! Privacy invariants: audio is in-memory PCM only; transcript text lives in
//! `mlock`ed, zero-on-drop pages (`store`) and never crosses the FFI boundary;
//! identifiers are scrubbed (`redact`) before any prompt is built (`prompt`).

uniffi::setup_scaffolding!("recordless_core");

mod alloc;
mod memory;
mod native_wipe;
mod nearai;
mod notes;
mod prompt;
mod redact;
mod secure;
mod session;
mod store;
mod vad;
mod vault;

pub use redact::ScrubOptions;
pub use session::{Session, UnfinishedWork};
pub use notes::{CheckOutcome, CloudModel, NotesResult, NotesStatus, VerificationCheck, VerificationReport};
pub use vault::{generate_vault_key, CreditStatus, NoteSummary, Vault};

/// Every Rust heap allocation is zeroed before it is returned to the system
/// (desktop `WipingAllocator`). whisper.cpp/ggml's C/C++ heap is wiped by
/// `native_wipe`; SQLCipher/OpenSSL/ring, system frameworks and GPU-private
/// memory are outside both.
#[global_allocator]
static GLOBAL: alloc::WipingAllocator = alloc::WipingAllocator;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("model load failed: {msg}")]
    ModelLoad { msg: String },
    #[error("inference failed: {msg}")]
    Inference { msg: String },
    #[error("memory lock failed: {msg}")]
    MemoryLock { msg: String },
    #[error("vault error: {msg}")]
    Vault { msg: String },
    #[error("invalid state: {msg}")]
    InvalidState { msg: String },
    /// Private cloud TEE verification failed; nothing but attestation
    /// evidence was sent. `Session.notes_status()` has the per-check report.
    #[error("private cloud verification failed: {msg}")]
    Attestation { msg: String },
    /// Any other private cloud failure (network, key, credit, response
    /// signature). The transcript is kept for retry.
    #[error("private cloud: {msg}")]
    PrivateCloud { msg: String },
    /// `Session.cancel_notes()` stopped the request. The transcript is kept.
    #[error("cancelled: {msg}")]
    Cancelled { msg: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SessionProgress {
    /// Transcribed speech segments held in the store.
    pub segments: u32,
    /// Speech audio covered by those segments.
    pub speech_ms: u64,
    /// Audio buffered but not yet transcribed (or discarded as silence).
    pub pending_ms: u64,
    /// Some inference failed; the partial transcript is kept.
    pub incomplete: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct SpeechStats {
    pub load_ms: u64,
    /// Audio seconds / compute seconds (higher is faster).
    pub realtime_factor: f64,
}

#[uniffi::export]
pub fn core_version() -> String {
    format!("recordless_core {}", env!("CARGO_PKG_VERSION"))
}

/// `task_vm_info.phys_footprint` in bytes (what jetsam enforces).
#[uniffi::export]
pub fn phys_footprint_bytes() -> u64 {
    memory::phys_footprint_bytes()
}

/// `ledger_phys_footprint_peak`, falling back to `resident_size_peak`.
#[uniffi::export]
pub fn peak_footprint_bytes() -> u64 {
    memory::peak_footprint_bytes()
}

/// Route whisper.cpp / ggml logging into the void. They do not log
/// transcript text with our parameters, but nothing native should hit stderr.
pub(crate) fn quiet_native_logs() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(whisper_rs::install_logging_hooks);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_reported() {
        assert!(core_version().starts_with("recordless_core "));
    }

    #[test]
    fn session_rejects_missing_model() {
        let err = Session::new("/nonexistent/ggml-model.bin".into(), false);
        assert!(matches!(err, Err(CoreError::ModelLoad { .. })), "{:?}", err.err());
    }

    /// Needs a whisper GGML model:
    /// `RECORDLESS_TEST_WHISPER=/path/ggml-base.en.bin cargo test -- --ignored`.
    #[test]
    #[ignore]
    fn session_lifecycle_with_real_model() {
        let path = std::env::var("RECORDLESS_TEST_WHISPER").expect("RECORDLESS_TEST_WHISPER");
        let session = Session::new(path, false).unwrap();
        let tone: Vec<f32> = (0..16_000 * 3)
            .map(|i| 0.3 * (i as f32 * 2.0 * std::f32::consts::PI * 220.0 / 16_000.0).sin())
            .collect();
        for chunk in tone.chunks(1600) {
            session.push_audio(chunk.to_vec()).unwrap();
        }
        session.push_audio(vec![0.0; 16_000]).unwrap();
        let progress = session.stop().unwrap();
        assert_eq!(progress.pending_ms, 0);
        assert!(session.push_audio(vec![0.0; 10]).is_err());
        session.discard();
        assert_eq!(session.progress().segments, 0);
    }
}
