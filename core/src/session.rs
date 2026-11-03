//! `Session`: in-memory audio -> energy VAD -> whisper.cpp -> locked transcript
//! store -> (after `stop`) scrubbed prompt -> attested private cloud notes.
//!
//! Audio and transcript text never leave this module except as the scrubbed
//! transcript handed to `notes::Run`, which sends it only over a TLS
//! connection whose TEE attestation passed. Swift sees counts and timings only.

use crate::nearai::{self, activation};
use crate::notes::{self, LiveStatus, NotesStatus, RunError};
use crate::redact::ScrubOptions;
use crate::vault::Vault;
use crate::secure::{disable_process_dumps, LockedBytes};
use crate::store::{StoredSegment, TranscriptStore};
use crate::vad::{EnergyVad, Utterance, SAMPLE_RATE};
use crate::{CoreError, NotesResult, SessionProgress, SpeechStats};
use tokio::sync::Notify;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState};
use zeroize::Zeroizing;

/// Pad utterances shorter than this; whisper.cpp rejects < 1 s of audio.
const MIN_WHISPER_SAMPLES: usize = SAMPLE_RATE * 1050 / 1000;

enum Msg {
    Audio(Vec<f32>),
    Stop,
}

#[derive(Default)]
struct Shared {
    store: Mutex<TranscriptStore>,
    pending_samples: AtomicU64,
    incomplete: AtomicBool,
    /// First locked-memory failure; reported from `stop()`.
    lock_error: Mutex<Option<String>>,
    transcribed_samples: AtomicU64,
    compute_us: AtomicU64,
}

impl Shared {
    fn store(&self) -> std::sync::MutexGuard<'_, TranscriptStore> {
        self.store.lock().unwrap_or_else(|p| p.into_inner())
    }
}

struct Worker {
    tx: Sender<Msg>,
    handle: JoinHandle<()>,
}

#[derive(uniffi::Object)]
pub struct Session {
    shared: Arc<Shared>,
    worker: Mutex<Option<Worker>>,
    load_ms: u64,
    /// One notes request per session at a time. Set and cleared only while
    /// `notes_cancel` is held; read lock-free for status.
    notes_running: AtomicBool,
    /// Cancels the request in flight; replaced for each request. This mutex is
    /// also the claim lock: a request is claimed (flag set and token
    /// installed) in one critical section, so `cancel_notes` can never fall
    /// between them, and `release_for_lock` holds it across its check and wipe
    /// so no request can start meanwhile, without borrowing the flag.
    notes_cancel: Mutex<Option<Arc<Notify>>>,
    notes_status: Arc<Mutex<LiveStatus>>,
    /// The app saved notes from this transcript; it is now held only so the
    /// notes can be regenerated, and lock may discard it.
    notes_saved: AtomicBool,
}

/// Work that locking would destroy. Lock is refused while any exists
/// (desktop CONFIDENTIAL.md step 7).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UnfinishedWork {
    /// Capture or transcription is still running (`stop()` not yet returned).
    Recording,
    /// A notes request is in flight.
    GeneratingNotes,
    /// A transcript is held and no notes from it have been saved.
    UnsavedTranscript,
}

fn samples_to_ms(samples: u64) -> u64 {
    samples * 1000 / SAMPLE_RATE as u64
}

fn threads() -> i32 {
    std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 4) as i32
}

#[uniffi::export]
impl Session {
    /// Loads the whisper model synchronously (so failures surface here), then
    /// starts the background transcription thread.
    #[uniffi::constructor]
    pub fn new(speech_model_path: String, use_gpu: bool) -> Result<Arc<Self>, CoreError> {
        disable_process_dumps().map_err(|msg| CoreError::MemoryLock { msg })?;
        if !crate::native_wipe::installed() {
            return Err(CoreError::MemoryLock { msg: "native heap wiping is not linked in".into() });
        }
        // Fail before capture if locked memory is unavailable.
        drop(LockedBytes::new(&[0; 65536]).map_err(|msg| CoreError::MemoryLock { msg })?);
        crate::quiet_native_logs();

        let started = Instant::now();
        let mut params = WhisperContextParameters::default();
        params.use_gpu = use_gpu;
        params.flash_attn = use_gpu;
        let ctx = WhisperContext::new_with_params(&speech_model_path, params)
            .map_err(|e| CoreError::ModelLoad { msg: format!("whisper model: {e}") })?;
        let state = ctx
            .create_state()
            .map_err(|e| CoreError::ModelLoad { msg: format!("whisper state: {e}") })?;
        drop(ctx); // the state keeps the model alive; dropping the state unloads it
        let load_ms = started.elapsed().as_millis() as u64;

        let shared = Arc::new(Shared::default());
        let (tx, rx) = mpsc::channel();
        let worker_shared = Arc::clone(&shared);
        let handle = std::thread::Builder::new()
            .name("recordless-speech".into())
            .spawn(move || run_worker(state, rx, worker_shared))
            .map_err(|e| CoreError::InvalidState { msg: format!("cannot start speech thread: {e}") })?;

        Ok(Arc::new(Self {
            shared,
            worker: Mutex::new(Some(Worker { tx, handle })),
            load_ms,
            notes_running: AtomicBool::new(false),
            notes_cancel: Mutex::new(None),
            notes_status: Arc::new(Mutex::new(LiveStatus::default())),
            notes_saved: AtomicBool::new(false),
        }))
    }

    /// Queue 16 kHz mono f32 samples. Returns immediately.
    pub fn push_audio(&self, samples: Vec<f32>) -> Result<(), CoreError> {
        let guard = self.worker.lock().unwrap_or_else(|p| p.into_inner());
        let worker = guard.as_ref().ok_or_else(|| CoreError::InvalidState { msg: "session is stopped".into() })?;
        let n = samples.len() as u64;
        self.shared.pending_samples.fetch_add(n, Ordering::SeqCst);
        if worker.tx.send(Msg::Audio(samples)).is_err() {
            self.shared.pending_samples.fetch_sub(n, Ordering::SeqCst);
            return Err(CoreError::Inference { msg: "speech thread exited".into() });
        }
        Ok(())
    }

    pub fn progress(&self) -> SessionProgress {
        let stats = self.shared.store().stats();
        SessionProgress {
            segments: stats.segments,
            speech_ms: stats.speech_ms,
            pending_ms: samples_to_ms(self.shared.pending_samples.load(Ordering::SeqCst)),
            incomplete: self.shared.incomplete.load(Ordering::SeqCst),
        }
    }

    /// Drain queued audio, transcribe it, unload the speech model, finalize the
    /// transcript. Idempotent. Reports a locked-memory failure as `MemoryLock`.
    pub fn stop(&self) -> Result<SessionProgress, CoreError> {
        self.shutdown_worker();
        self.shared.store().finalize();
        if let Some(msg) = self.shared.lock_error.lock().unwrap_or_else(|p| p.into_inner()).clone() {
            return Err(CoreError::MemoryLock { msg });
        }
        Ok(self.progress())
    }

    pub fn speech_stats(&self) -> SpeechStats {
        let audio_s = self.shared.transcribed_samples.load(Ordering::SeqCst) as f64 / SAMPLE_RATE as f64;
        let compute_s = self.shared.compute_us.load(Ordering::SeqCst) as f64 / 1e6;
        SpeechStats {
            load_ms: self.load_ms,
            realtime_factor: if compute_s > 0.0 { audio_s / compute_s } else { 0.0 },
        }
    }

    /// Valid only after `stop()`. Scrubs the transcript as `scrub` says (in
    /// Rust, before any prompt is built), then sends it to the private cloud
    /// model `model_id` (or the recommended one) only over a connection whose
    /// TEE attestation passed, and accepts the reply only with a valid
    /// signature from the attested key. Blocking, network-bound.
    ///
    /// One request per session at a time (`InvalidState` otherwise). The
    /// transcript stays in memory after success, failure or cancellation, so
    /// notes can be retried or regenerated, until `discard()`.
    pub fn generate_notes(
        &self,
        vault: Arc<Vault>,
        model_id: Option<String>,
        scrub: ScrubOptions,
    ) -> Result<NotesResult, CoreError> {
        if self.worker.lock().unwrap_or_else(|p| p.into_inner()).is_some() {
            return Err(CoreError::InvalidState { msg: "call stop() before generate_notes()".into() });
        }
        let (_claim, cancel) = self.claim_notes()?;
        *self.notes_status.lock().unwrap_or_else(|p| p.into_inner()) = LiveStatus::default();

        // A success clears a credit run-out only if this run began after it.
        let run_started = chrono::Utc::now();
        let started = Instant::now();
        let api_key = vault
            .private_cloud_key()?
            .ok_or_else(|| CoreError::PrivateCloud { msg: activation::NO_ACTIVATION.into() })?;

        let transcript = {
            let store = self.shared.store();
            if !store.is_finalized() {
                return Err(CoreError::InvalidState { msg: "call stop() before generate_notes()".into() });
            }
            store.transcript_for_llm(&scrub)
        };
        let transcript = Zeroizing::new(
            transcript.ok_or_else(|| CoreError::InvalidState { msg: "no speech was transcribed".into() })?,
        );

        let run = notes::Run { api_key: &api_key, model_id, scrub, status: Arc::clone(&self.notes_status) };
        let outcome = nearai::runtime().block_on(async {
            tokio::select! {
                result = run.run(&transcript) => Some(result),
                _ = cancel.notified() => None,
            }
        });
        drop(transcript);
        drop(api_key);
        let elapsed_ms = started.elapsed().as_millis() as u64;
        let mut status = self.notes_status.lock().unwrap_or_else(|p| p.into_inner());
        status.step = None;

        match outcome {
            None => Err(CoreError::Cancelled { msg: "notes generation was cancelled; the transcript is kept".into() }),
            Some(Ok((markdown, model, totals))) => {
                activation::remember_credit_works(&*vault, run_started);
                Ok(notes::into_result(markdown, model, totals, &status, elapsed_ms))
            }
            Some(Err(RunError::Attestation(msg))) => Err(CoreError::Attestation { msg }),
            Some(Err(RunError::Cloud(msg))) => {
                let msg = activation::run_error(msg);
                if msg == activation::CREDIT_USED_UP {
                    activation::remember_credit_used_up(&*vault);
                }
                Err(CoreError::PrivateCloud { msg })
            }
        }
    }

    /// Stop the notes request in flight, if any. Its connection is dropped; the
    /// transcript is kept. `generate_notes` then returns `Cancelled`.
    pub fn cancel_notes(&self) {
        // `notify_one` stores a permit when nothing is waiting yet, so a cancel
        // that lands after the claim but before the request awaits still wins.
        if let Some(cancel) = self.notes_claim().as_ref() {
            cancel.notify_one();
        }
    }

    /// Progress of the notes request (step labels, request n of m) and the
    /// latest verification report, which is kept after a failure.
    pub fn notes_status(&self) -> NotesStatus {
        let status = self.notes_status.lock().unwrap_or_else(|p| p.into_inner());
        NotesStatus {
            running: self.notes_running.load(Ordering::SeqCst),
            step: status.step.clone(),
            request: status.request,
            requests: status.requests,
            last_verification: status.last_verification.clone(),
        }
    }

    /// What locking would destroy right now, if anything. Checked in this
    /// order: recording, notes in flight, a held transcript without saved notes.
    pub fn unfinished_work(&self) -> Option<UnfinishedWork> {
        if self.notes_running.load(Ordering::SeqCst) {
            return Some(UnfinishedWork::GeneratingNotes);
        }
        self.unfinished_besides_notes()
    }

    /// Record that notes from this transcript were saved to the vault. The
    /// transcript is still held (for regeneration) but no longer blocks lock.
    pub fn mark_notes_saved(&self) {
        self.notes_saved.store(true, Ordering::SeqCst);
    }

    /// The lock path. Refuses, returning the reason, while there is unfinished
    /// work; otherwise wipes the transcript store (as `discard()`) and returns
    /// `None`. Atomic with respect to `generate_notes`: a request cannot start
    /// between the check and the wipe.
    pub fn release_for_lock(&self) -> Option<UnfinishedWork> {
        // Holding the claim lock (not the running flag) keeps a request from
        // starting until the wipe is done; a concurrent `generate_notes` waits
        // briefly and then finds no transcript, and `notes_status` never
        // reports a phantom request.
        let _claim = self.notes_claim();
        if self.notes_running.load(Ordering::SeqCst) {
            return Some(UnfinishedWork::GeneratingNotes);
        }
        if let Some(work) = self.unfinished_besides_notes() {
            return Some(work);
        }
        let mut store = self.shared.store();
        store.discard();
        store.finalize();
        None
    }

    /// Stop transcription (if running), cancel a notes request in flight, and
    /// wipe the transcript store. Always succeeds, whatever is unfinished.
    pub fn discard(&self) {
        self.cancel_notes();
        self.shutdown_worker();
        let mut store = self.shared.store();
        store.discard();
        store.finalize();
    }
}

/// A claimed notes request. Dropping it clears the cancel token and the
/// running flag together, under the claim lock.
struct NotesClaim<'a>(&'a Session);

impl Drop for NotesClaim<'_> {
    fn drop(&mut self) {
        let mut slot = self.0.notes_claim();
        slot.take();
        self.0.notes_running.store(false, Ordering::SeqCst);
    }
}

impl Session {
    fn notes_claim(&self) -> std::sync::MutexGuard<'_, Option<Arc<Notify>>> {
        self.notes_cancel.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Claim the session's one notes request: set the running flag and
    /// install a fresh cancel token in one critical section.
    fn claim_notes(&self) -> Result<(NotesClaim<'_>, Arc<Notify>), CoreError> {
        let mut slot = self.notes_claim();
        if self.notes_running.load(Ordering::SeqCst) {
            return Err(CoreError::InvalidState { msg: "notes are already being generated for this session".into() });
        }
        let cancel = Arc::new(Notify::new());
        *slot = Some(Arc::clone(&cancel));
        self.notes_running.store(true, Ordering::SeqCst);
        drop(slot);
        Ok((NotesClaim(self), cancel))
    }

    fn unfinished_besides_notes(&self) -> Option<UnfinishedWork> {
        if self.worker.lock().unwrap_or_else(|p| p.into_inner()).is_some() {
            return Some(UnfinishedWork::Recording);
        }
        if !self.shared.store().is_empty() && !self.notes_saved.load(Ordering::SeqCst) {
            return Some(UnfinishedWork::UnsavedTranscript);
        }
        None
    }

    fn shutdown_worker(&self) {
        let worker = self.worker.lock().unwrap_or_else(|p| p.into_inner()).take();
        if let Some(worker) = worker {
            let _ = worker.tx.send(Msg::Stop);
            if worker.handle.join().is_err() {
                self.shared.incomplete.store(true, Ordering::SeqCst);
            }
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.shutdown_worker();
        self.shared.store().discard();
    }
}

/// Owns the whisper state; dropping it at the end of this function unloads the model.
fn run_worker(mut state: WhisperState, rx: Receiver<Msg>, shared: Arc<Shared>) {
    let mut vad = EnergyVad::default();
    let mut sequence = 0u64;
    let mut handle = |out: crate::vad::Output, state: &mut WhisperState| {
        shared.pending_samples.fetch_sub(out.discarded, Ordering::SeqCst);
        for utterance in out.utterances {
            let n = utterance.samples.len() as u64;
            transcribe(state, &utterance, sequence, &shared);
            sequence += 1;
            shared.pending_samples.fetch_sub(n, Ordering::SeqCst);
        }
    };
    loop {
        match rx.recv() {
            Ok(Msg::Audio(samples)) => {
                let out = vad.push(&samples);
                handle(out, &mut state);
            }
            Ok(Msg::Stop) | Err(_) => {
                // Anything still queued behind Stop is dropped, as is its pending count.
                let out = vad.flush();
                handle(out, &mut state);
                while let Ok(msg) = rx.try_recv() {
                    if let Msg::Audio(s) = msg {
                        shared.pending_samples.fetch_sub(s.len() as u64, Ordering::SeqCst);
                    }
                }
                break;
            }
        }
    }
    drop(state);
}

fn transcribe(state: &mut WhisperState, utterance: &Utterance, sequence_id: u64, shared: &Shared) {
    let mut audio = std::borrow::Cow::Borrowed(&utterance.samples[..]);
    if audio.len() < MIN_WHISPER_SAMPLES {
        let mut padded = audio.into_owned();
        padded.resize(MIN_WHISPER_SAMPLES, 0.0);
        audio = std::borrow::Cow::Owned(padded);
    }

    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(threads());
    params.set_language(Some("en"));
    params.set_translate(false);
    params.set_no_context(true);
    params.set_no_timestamps(true);
    params.set_single_segment(false);
    params.set_suppress_blank(true);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);

    let started = Instant::now();
    let result = state.full(params, &audio);
    shared.compute_us.fetch_add(started.elapsed().as_micros() as u64, Ordering::SeqCst);
    if result.is_err() {
        shared.incomplete.store(true, Ordering::SeqCst);
        return;
    }
    shared.transcribed_samples.fetch_add(utterance.samples.len() as u64, Ordering::SeqCst);

    // Pre-size so pushing does not reallocate (and leave unwiped copies).
    let mut text = String::with_capacity(8192);
    for i in 0..state.full_n_segments() {
        let Some(segment) = state.get_segment(i) else { continue };
        match segment.to_str_lossy() {
            Ok(piece) => text.push_str(&piece),
            Err(_) => shared.incomplete.store(true, Ordering::SeqCst),
        }
    }
    let stored = StoredSegment {
        sequence_id,
        text,
        audio_start_ms: samples_to_ms(utterance.start_sample),
        audio_end_ms: samples_to_ms(utterance.end_sample()),
    };
    if let Err(msg) = shared.store().record_segment(stored) {
        shared.incomplete.store(true, Ordering::SeqCst);
        let mut slot = shared.lock_error.lock().unwrap_or_else(|p| p.into_inner());
        slot.get_or_insert(msg);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future::Future;

    /// A stopped session holding `segments` transcript segments, no model.
    fn stopped_session(segments: u64) -> Session {
        let shared = Arc::new(Shared::default());
        {
            let mut store = shared.store();
            for i in 0..segments {
                store
                    .record_segment(StoredSegment {
                        sequence_id: i,
                        text: format!("segment {i} text"),
                        audio_start_ms: i * 1000,
                        audio_end_ms: i * 1000 + 900,
                    })
                    .unwrap();
            }
            store.finalize();
        }
        Session {
            shared,
            worker: Mutex::new(None),
            load_ms: 0,
            notes_running: AtomicBool::new(false),
            notes_cancel: Mutex::new(None),
            notes_status: Arc::new(Mutex::new(LiveStatus::default())),
            notes_saved: AtomicBool::new(false),
        }
    }

    #[test]
    fn lock_is_refused_while_a_transcript_has_no_saved_notes() {
        let s = stopped_session(2);
        assert_eq!(s.unfinished_work(), Some(UnfinishedWork::UnsavedTranscript));
        assert_eq!(s.release_for_lock(), Some(UnfinishedWork::UnsavedTranscript));
        assert_eq!(s.progress().segments, 2, "refused lock keeps the transcript");
    }

    #[test]
    fn lock_discards_a_transcript_kept_only_for_regeneration() {
        let s = stopped_session(2);
        s.mark_notes_saved();
        assert_eq!(s.unfinished_work(), None);
        assert_eq!(s.release_for_lock(), None);
        assert_eq!(s.progress().segments, 0);
        assert!(!s.notes_running.load(Ordering::SeqCst), "lock never sets the running flag");
    }

    #[test]
    fn lock_is_refused_while_notes_are_generating() {
        let s = stopped_session(1);
        s.mark_notes_saved();
        s.notes_running.store(true, Ordering::SeqCst);
        assert_eq!(s.unfinished_work(), Some(UnfinishedWork::GeneratingNotes));
        assert_eq!(s.release_for_lock(), Some(UnfinishedWork::GeneratingNotes));
        assert!(s.notes_running.load(Ordering::SeqCst), "a refused lock leaves the request's flag alone");
        assert_eq!(s.progress().segments, 1);
    }

    #[test]
    fn lock_is_refused_while_recording() {
        let s = stopped_session(0);
        let (tx, _rx) = mpsc::channel();
        let handle = std::thread::spawn(|| {});
        *s.worker.lock().unwrap() = Some(Worker { tx, handle });
        assert_eq!(s.unfinished_work(), Some(UnfinishedWork::Recording));
        assert_eq!(s.release_for_lock(), Some(UnfinishedWork::Recording));
        s.discard();
        assert_eq!(s.unfinished_work(), None, "discard always works");
    }

    #[test]
    fn empty_stopped_session_does_not_block_lock() {
        let s = stopped_session(0);
        assert_eq!(s.unfinished_work(), None);
        assert_eq!(s.release_for_lock(), None);
    }

    /// True if `cancel` has a pending notification (polled once, no runtime).
    fn is_cancelled(cancel: &Notify) -> bool {
        let fut = std::pin::pin!(cancel.notified());
        let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
        fut.poll(&mut cx).is_ready()
    }

    #[test]
    fn cancel_right_after_claim_is_not_lost() {
        let s = Arc::new(stopped_session(1));
        for _ in 0..500 {
            let canceller = {
                let s = Arc::clone(&s);
                std::thread::spawn(move || {
                    // Cancel as soon as the request is visible as running.
                    while !s.notes_status().running {
                        std::hint::spin_loop();
                    }
                    s.cancel_notes();
                })
            };
            let (claim, cancel) = s.claim_notes().expect("claim");
            canceller.join().unwrap();
            assert!(is_cancelled(&cancel), "a cancel after the claim reaches the request");
            drop(claim);
            assert!(!s.notes_status().running);
            assert!(s.notes_cancel.lock().unwrap().is_none(), "the claim clears its token");
        }
    }

    #[test]
    fn second_claim_is_refused_while_one_runs() {
        let s = stopped_session(1);
        let (claim, _cancel) = s.claim_notes().unwrap();
        assert!(matches!(s.claim_notes(), Err(CoreError::InvalidState { .. })));
        assert_eq!(s.release_for_lock(), Some(UnfinishedWork::GeneratingNotes));
        drop(claim);
        assert!(s.claim_notes().is_ok());
    }

    #[test]
    fn lock_in_progress_does_not_look_like_a_notes_request() {
        let s = Arc::new(stopped_session(1));
        s.mark_notes_saved();
        // Hold the claim lock exactly as `release_for_lock` does mid-wipe.
        let held = s.notes_claim();
        assert!(!s.notes_status().running, "status does not report a phantom request");
        assert_eq!(s.notes_running.load(Ordering::SeqCst), false);
        let claimer = {
            let s = Arc::clone(&s);
            std::thread::spawn(move || s.claim_notes().map(|(claim, _)| drop(claim)).is_ok())
        };
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(!claimer.is_finished(), "a request waits for the lock to finish instead of failing");
        drop(held);
        assert!(claimer.join().unwrap(), "the request is not refused as already running");
        // And a real lock leaves the flag untouched afterwards.
        assert_eq!(s.release_for_lock(), None);
        assert!(!s.notes_status().running);
        assert!(s.claim_notes().is_ok());
    }

    #[test]
    fn discard_works_with_unsaved_transcript() {
        let s = stopped_session(3);
        s.discard();
        assert_eq!(s.progress().segments, 0);
        assert_eq!(s.unfinished_work(), None);
    }
}
