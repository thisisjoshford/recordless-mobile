//! Recordless on-device core (phase-0 spike). FFI contract: docs/core-ffi.md.
//!
//! Privacy invariants: audio is in-memory PCM only; transcript text lives in
//! `mlock`ed, zero-on-drop pages (`store`) and never crosses the FFI boundary;
//! identifiers are scrubbed (`redact`) before any prompt is built (`prompt`).

uniffi::setup_scaffolding!("recordless_core");

mod alloc;
mod local_notes;
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
pub use notes::{
    CheckOutcome, CloudModel, LocalNotesStats, NotesLocation, NotesResult, NotesStatus, VerificationCheck,
    VerificationReport,
};
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
    /// On-device notes failed (model load, out of memory, inference). The
    /// transcript is kept for retry.
    #[error("on-device notes: {msg}")]
    LocalNotes { msg: String },
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
    /// The voice-activity detector is inside speech right now (an utterance
    /// is being collected; it is transcribed after a pause or 28 s).
    pub in_speech: bool,
    /// The speech model is transcribing an utterance right now.
    pub transcribing: bool,
}

/// Counters for diagnosing the capture -> VAD -> whisper path. Counts and
/// coarse levels only (whole dBFS, loudest 30 ms frame per ~1 s); no audio
/// and no text.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct SessionDiagnostics {
    /// `push_audio` calls and samples received (16 kHz, so samples / 16000 = s).
    pub chunks_received: u64,
    pub samples_received: u64,
    /// 30 ms VAD frames seen, and how many were judged speech.
    pub vad_frames: u64,
    pub vad_speech_frames: u64,
    /// Utterances closed for transcription, and ones dropped as too short.
    pub utterances: u64,
    pub utterances_dropped: u64,
    /// Loudest frame in the last ~1 s, the adaptive noise floor and the speech
    /// threshold, in whole dBFS (-100 for silence).
    pub level_dbfs: i32,
    pub noise_floor_dbfs: i32,
    pub threshold_dbfs: i32,
    /// whisper runs, failed runs, and runs that produced no text.
    pub inference_runs: u64,
    pub inference_failures: u64,
    pub empty_results: u64,
    pub last_inference_ms: u64,
    /// The GPU failed (for example while the screen was locked) and speech
    /// moved to the CPU for the rest of the session.
    pub gpu_fallback: bool,
    /// Reloading the speech model on the CPU after a GPU failure also failed:
    /// the rest of the audio is not transcribed (`incomplete` is set).
    pub speech_unavailable: bool,
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

/// CPU threads for whisper and llama.cpp (shared so speech and notes agree).
pub(crate) fn inference_threads() -> i32 {
    std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 4) as i32
}

/// Route whisper.cpp, llama.cpp and ggml logging into the void. They do not
/// log transcript text with our parameters, but nothing native should hit
/// stderr. ggml is shared, so either hook silences it.
pub(crate) fn quiet_native_logs() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        whisper_rs::install_logging_hooks();
        llama_cpp_2::send_logs_to_tracing(llama_cpp_2::LogOptions::default().with_logs_enabled(false));
    });
}

/// RMS -> whole dBFS, -100 for silence.
pub(crate) fn dbfs(rms: f32) -> i32 {
    if rms <= 1e-5 {
        -100
    } else {
        (20.0 * rms.log10()).round().max(-100.0) as i32
    }
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

    /// 16-bit PCM mono WAV -> f32 samples (test fixtures only).
    fn read_wav_16k_mono(path: &str) -> Vec<f32> {
        let bytes = std::fs::read(path).unwrap();
        let mut i = 12;
        while i + 8 <= bytes.len() {
            let id = &bytes[i..i + 4];
            let len = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap()) as usize;
            if id == b"data" {
                return bytes[i + 8..(i + 8 + len).min(bytes.len())]
                    .chunks_exact(2)
                    .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0)
                    .collect();
            }
            i += 8 + len + (len & 1);
        }
        panic!("no data chunk in {path}");
    }

    /// Synthetic speech end to end on the host, the same path as the app's
    /// DEBUG `-selftest`: `scripts/make-selftest-fixture.sh out.wav`, then
    /// `RECORDLESS_TEST_WHISPER=… RECORDLESS_TEST_FIXTURE=out.wav
    /// [RECORDLESS_TEST_LLM=Qwen3.5-2B-Q4_K_M.gguf] cargo test -p recordless_core
    /// synthetic_speech -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn synthetic_speech_is_transcribed_and_summarised() {
        let model = std::env::var("RECORDLESS_TEST_WHISPER").expect("RECORDLESS_TEST_WHISPER");
        let audio = read_wav_16k_mono(&std::env::var("RECORDLESS_TEST_FIXTURE").expect("RECORDLESS_TEST_FIXTURE"));
        let session = Session::new(model, true).unwrap();
        for chunk in audio.chunks(1600) {
            session.push_audio(chunk.to_vec()).unwrap();
        }
        let progress = session.stop().unwrap();
        let d = session.diagnostics();
        eprintln!("progress {progress:?}\ndiagnostics {d:?}\nspeech {:?}", session.speech_stats());
        assert_eq!(d.samples_received, audio.len() as u64);
        assert!(d.utterances >= 3, "{d:?}");
        assert!(progress.segments >= 3, "{progress:?}");
        assert_eq!(d.inference_failures, 0);

        if let Ok(llm) = std::env::var("RECORDLESS_TEST_LLM") {
            let gpu = std::env::var("RECORDLESS_TEST_LLM_CPU").is_err();
            let r = session.generate_notes_on_device(llm, gpu, ScrubOptions::all()).unwrap();
            eprintln!("{}\n{:?} requests {} prompt {} generated {} elapsed {} ms", r.markdown, r.local, r.requests, r.prompt_tokens, r.generated_tokens, r.elapsed_ms);
            assert_eq!(r.location, NotesLocation::OnDevice);
            assert!(r.markdown.contains('#'));
        }
    }
}
