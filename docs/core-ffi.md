# recordless-core FFI contract (phase 0 spike)

The Swift app talks to the Rust core only through this UniFFI surface
(proc-macro style, `uniffi::setup_scaffolding!("recordless_core")`).
Both sides build against it; change it here first.

## Layout

- `core/` — Rust crate `recordless_core` (`crate-type = ["staticlib", "lib"]`).
- `scripts/build-xcframework.sh` — builds `aarch64-apple-ios` and
  `aarch64-apple-ios-sim`, writes `ios/Frameworks/RecordlessCore.xcframework`
  and the generated Swift bindings to `ios/Generated/` (both gitignored).
- `ios/` — XcodeGen `project.yml` + SwiftUI app `Recordless`.

## Privacy rules (same as desktop CONFIDENTIAL.md)

- Audio arrives as in-memory PCM only; nothing is written to disk.
- Transcript text never crosses the FFI boundary. Swift sees counts/timings.
- Transcript segments live in a zeroize-on-drop store (port of desktop
  `confidential/store.rs`); `mlock` is attempted, failure is reported, not ignored.
- Scrubbing (port of desktop `confidential/redact.rs`) happens in Rust before
  any prompt is built. `ScrubOptions` default is everything on.
- Notes are written **on the device by default** (llama.cpp in process,
  `core/src/local_notes.rs`; the GGUF is loaded, used and unloaded inside one
  call, after the speech model is unloaded). Optionally they come from the
  private cloud: a NEAR AI model in a TEE, used only after attestation passes
  on the same TLS connection that carries the prompt, and only from NEAR AI's
  TEE host list (port of desktop `summary/nearai/`). The response must be
  signed by the attested key. Scrubbing and privacy rules are identical for both.
- The NEAR AI key is stored in the vault and never returned to Swift. See
  `CONFIDENTIAL-ios.md`.

## Surface

```text
fn core_version() -> String
fn phys_footprint_bytes() -> u64            // task_vm_info.phys_footprint
fn peak_footprint_bytes() -> u64            // ledger_phys_footprint_peak / resident_size_peak

record ScrubOptions { emails: bool, phones: bool, urls: bool, numbers: bool, names: bool }

record SessionProgress {
  segments: u32,           // transcribed speech segments held in the store
  speech_ms: u64,          // speech audio covered by those segments
  pending_ms: u64,         // audio buffered but not yet transcribed
  incomplete: bool,        // some inference failed; partial transcript kept
  in_speech: bool,         // VAD is inside an utterance (transcribed after a pause / 28 s)
  transcribing: bool,      // whisper is running on an utterance now
}

record SessionDiagnostics {  // counts and whole-dBFS levels only; no audio, no text
  chunks_received: u64, samples_received: u64,          // push_audio calls / 16 kHz samples
  vad_frames: u64, vad_speech_frames: u64,              // 30 ms frames
  utterances: u64, utterances_dropped: u64,             // closed for whisper / too short
  level_dbfs: i32, noise_floor_dbfs: i32, threshold_dbfs: i32,  // loudest frame in last ~1 s
  inference_runs: u64, inference_failures: u64, empty_results: u64, last_inference_ms: u64,
  gpu_fallback: bool,      // a GPU run failed; speech moved to the CPU for the session
}

record SpeechStats { load_ms: u64, realtime_factor: f64 }   // audio secs / compute secs

enum NotesLocation { OnDevice, PrivateCloud }

record LocalNotesStats {
  load_ms: u64, prompt_ms: u64, generate_ms: u64,
  prompt_tokens_per_s: f64, tokens_per_s: f64,           // prefill / generation
  context_tokens: u32,     // 8192
  peak_footprint_bytes: u64,                             // ledger peak when the run ended
  gpu: bool,
}

record NotesResult {
  markdown: String,        // generated notes (allowed to cross; transcript is not)
  model_id: String,        // cloud model id, or the GGUF file name
  location: NotesLocation,
  verification: Option<VerificationReport>,   // private cloud only
  local: Option<LocalNotesStats>,             // on device only
  prompt_tokens: u32,      // summed over every request
  generated_tokens: u32,
  requests: u32,           // chunks + combine(s) + final for long meetings, else 1
  elapsed_ms: u64,
}

enum CheckOutcome { Passed, Unread, Failed, NotRun }
record VerificationCheck { id: String, label: String, outcome: CheckOutcome, detail: Option<String> }
  // ids, in order: connect, model, hardware, binding, software, deploy, weights, gpu, signature
record VerificationReport {
  model_id: String, host: Option<String>,
  passed: bool,            // no check failed and the signature passed (unread does not fail it)
  checks: Vec<VerificationCheck>, tcb_status: Option<String>, attested_requests: u32,
}
record NotesStatus { running: bool, step: Option<String>, request: u32, requests: u32,
                     last_verification: Option<VerificationReport> }   // kept after a failure
record CloudModel { id, display_name, description?, context_length?, max_output_tokens?,
                    input_price?, output_price?,            // USD per million tokens
                    suggestion_label?, suggestion_reason?, recommended: bool }
record CreditStatus {
  active: bool,            // a code (or own key) is stored in this vault
  available: bool,         // build has RECORDLESS_TRIAL_URL (activation codes possible)
  own_key: bool, credit_used_up: bool,
  checked: bool,           // the credit service was asked in this call
  payment_pending: bool, expires_at: Option<String>, disabled: bool,
  upgrade_url: Option<String>, check_error: Option<String>,
}

enum CoreError { ModelLoad(msg), Inference(msg), MemoryLock(msg), Vault(msg), InvalidState(msg),
                 Attestation(msg),   // TEE verification failed; nothing but attestation evidence sent
                 PrivateCloud(msg),  // network / key / credit / response-signature / model output
                 Cancelled(msg),     // cancel_notes(); transcript kept
                 LocalNotes(msg) }   // on-device inference failed; transcript kept

object Session {
  constructor new(speech_model_path: String, use_gpu: bool) -> Result<Session, CoreError>
  fn push_audio(samples: Vec<f32>) -> Result<(), CoreError>   // 16 kHz mono f32, any chunk size
  fn progress() -> SessionProgress
  fn stop() -> Result<SessionProgress, CoreError>              // drains, then unloads speech model
  fn speech_stats() -> SpeechStats
  fn diagnostics() -> SessionDiagnostics
  fn generate_notes_on_device(model_path: String, use_gpu: bool, scrub: ScrubOptions)
      -> Result<NotesResult, CoreError>                        // valid only after stop(); scrubs, then
                                                               // llama.cpp in process: load, run, unload
  fn generate_notes(vault: Vault, model_id: Option<String>, scrub: ScrubOptions) -> Result<NotesResult, CoreError>
                                                               // valid only after stop(); scrubs, then
                                                               // attested private cloud request(s)
  fn cancel_notes()                                            // drops the cloud request / stops local at the next token
  fn notes_status() -> NotesStatus
  fn discard()                                                 // cancels notes, wipes transcript store; always allowed
  fn unfinished_work() -> Option<UnfinishedWork>               // what lock would destroy, if anything
  fn mark_notes_saved()                                        // notes saved: transcript no longer blocks lock
  fn release_for_lock() -> Option<UnfinishedWork>              // lock path: Some(reason) = refused, nothing
                                                               // changed; None = transcript wiped
}

enum UnfinishedWork { Recording,           // stop() has not returned
                      GeneratingNotes,     // a notes request is in flight
                      UnsavedTranscript }  // transcript held, mark_notes_saved() not called

fn generate_vault_key() -> Result<Vec<u8>, CoreError>       // 32 random bytes (getentropy)

object Vault {
  constructor create(path: String, key: Vec<u8>) -> Result<Vault, CoreError>   // key: exactly 32 bytes
  constructor open(path: String, key: Vec<u8>) -> Result<Vault, CoreError>
  fn save_note(title: String, markdown: String) -> Result<String, CoreError>   // returns id
  fn list_notes() -> Result<Vec<NoteSummary>, CoreError>
  fn read_note(id: String) -> Result<String, CoreError>
  fn close()
  // Private cloud (core/src/vault/cloud.rs). Network calls; blocking.
  fn redeem_activation(code: String) -> Result<CreditStatus, CoreError>   // also takes an `sk-…` key
  fn private_cloud_status() -> Result<CreditStatus, CoreError>
  fn list_private_cloud_models() -> Result<Vec<CloudModel>, CoreError>
}
record NoteSummary { id: String, title: String, created_at_ms: i64 }
```

All Session/Vault methods are blocking; Swift calls them off the main actor.
`push_audio` must return quickly (queue + background transcription thread).

## Implementation notes (core, phase 0)

Surface above is implemented as written. Details the Swift side can rely on:

- Swift names: `Session(speechModelPath:useGpu:)`, `session.generateNotes(vault:modelId:scrub:)`,
  `vault.redeemActivation(code:)`, `vault.privateCloudStatus()`, `vault.listPrivateCloudModels()`,
  `generateVaultKey() -> Data`,
  `Vault.create(path:key:)`, ``Vault.`open`(path:key:)`` (`key: Data`), `CoreError.ModelLoad(msg:)` etc. `ScrubOptions()`
  defaults every field to `true`.
- A wrong vault key is `CoreError.Vault(msg: "wrong-key")`; a key that is not 32 bytes is
  another `Vault` error. `Vault.create` refuses to overwrite an existing non-empty file;
  `Vault.open` requires one. There are no passphrase constructors.
- **Key handling.** The vault is SQLCipher keyed with a 32-byte raw key
  (`PRAGMA key = "x'<hex>'"`, no PBKDF2). Rust generates it (`generate_vault_key`, OS
  CSPRNG); Rust copies (the `Vec`, the hex PRAGMA string) are `Zeroizing` and the wiping
  allocator zeroes freed Rust heap, including FFI buffers Rust frees. iOS wraps the key with a
  Secure Enclave P-256 key (ECIES `eciesEncryptionCofactorVariableIVX963SHA256AESGCM`,
  access `[.privateKeyUsage, .userPresence]`), stores the wrapped blob in the keychain
  (`WhenPasscodeSetThisDeviceOnly`), and wipes its `Data` copy after `Vault.open`. Losing the
  SE key or blob (e.g. passcode removed) makes the vault permanently unreadable; the app sets
  the file aside under `vault-set-aside-<time>` and never deletes it.
- `Session.new` fails with `MemoryLock` if `mlock` or core-dump disabling fails. A later
  lock failure marks `incomplete` and makes `stop()` return `MemoryLock`.
- `stop()` is idempotent; `push_audio` after `stop()`/`discard()` is `InvalidState`.
  `generate_notes` before `stop()` or with no transcribed speech is `InvalidState`.
- VAD is a simple energy VAD (30 ms frames, adaptive floor, 750 ms hangover, 28 s cap).
  Whisper runs English-only, greedy, `use_gpu` + flash-attn toggled together. If a GPU
  run fails (iOS refuses GPU work in the background, e.g. screen locked), the session
  reloads the model on the CPU, retries that utterance and stays on the CPU
  (`diagnostics().gpu_fallback`).
- **On-device notes** (`generate_notes_on_device`, `core/src/local_notes.rs`). Needs
  `stop()` first (so the speech model is unloaded) and no other request on the session.
  Loads the GGUF (`n_gpu_layers` all or 0), runs, and drops model and contexts before
  returning. Context 8192 tokens, a fresh context per request; budgets are measured with
  the model's tokenizer: final notes get up to 1536 output tokens, chunks 640, combines
  1024. A transcript that does not fit one final request is chunked (desktop
  `chunk_text`, re-split until each chunk fits), each chunk summarised, the summaries
  combined in groups that fit, then written up with the `confidential_meeting` template.
  Qwen3.5 non-thinking chat template and desktop's `qwen35_summary` sampling (temp 0.5,
  top-k 20, top-p 0.8, presence 0.3, repeat 1.05 over 256). An empty or reasoning-only
  answer is retried once. Errors: `ModelLoad` (GGUF), `LocalNotes` (inference),
  `Cancelled`. `notes_status()` reports steps ("Summarising part 2 of 3", …).
  `verification` is `None`; `local` has the timings.
- **Private cloud notes** (`core/src/notes.rs`, `core/src/nearai/`). `generate_notes`
  needs `stop()` first, an open vault holding an activation (else
  `PrivateCloud(msg: "Enter an activation code to use the private cloud.")`), and no other
  request on the session (`InvalidState`). `model_id: nil` uses the model flagged
  `recommended` (NEAR AI's catalogue entry for our "Recommended" suggestion, else the first
  listed); a named model NEAR AI no longer lists still goes to verification, which decides.
  Desktop's flow is ported: transcripts whose rough token count reaches the model's chunk
  budget (`(ctx - 20k) * 0.8`, 4k..100k, 24k if unknown) are chunked, each chunk
  summarised (retried once unless timed out), combined, then written up with the
  `confidential_meeting` template; otherwise one request. **Every request is attested
  separately.** Output is cleaned of `<think>` envelopes and must have visible content.
  English only (desktop's translation/normalisation/cache are not ported).
- Verification checks map to desktop's stages. `Unread` = desktop "skipped stage" (deploy
  manager not named by the manifest; weights unpinned or deployment unreadable). A failure
  marks that check `Failed`, later ones `NotRun`, and returns `Attestation`;
  `notes_status().last_verification` keeps the report. A bad/missing response signature is
  `PrivateCloud` with the `signature` check `Failed`.
- A NEAR AI key rejection (HTTP 401/402/403) becomes
  `PrivateCloud(msg: "Your private cloud credit has run out, or your activation code has expired.")`
  and records a run-out in the vault; `private_cloud_status()` then asks the credit service
  (account id + key, never content). Only a later successful run, a new code, or a raised
  limit clears it. An own `sk-` key is never sent to the credit service.
- `redeem_activation` validates the key with NEAR AI (empty chat request → 400 means
  accepted) before saving it in the vault's `private_cloud` table. The credit service URL is
  compiled in from `RECORDLESS_TRIAL_URL` at build time (`available: false` without it).
- Failed, cancelled or successful requests all keep the transcript; `discard()` wipes it.
- **Lock** (desktop CONFIDENTIAL.md step 7). The app locks only through
  `release_for_lock()`, then `Vault.close()`. It refuses while recording, while a
  request runs, or while a non-empty transcript has no saved notes, and is atomic
  with `generate_notes` (a request cannot start between the check and the wipe;
  one that tries gets `InvalidState`). The app also treats its own
  loading/stopping and in-flight generation as unfinished before asking the core.
- **Native heap wiping** (`core/native/`, `core/src/native_wipe.rs`). `build.rs`
  compiles `wipe.cpp` (replacement C++ `operator new`/`delete`, wiping
  `free`/`realloc`), linked whole-archive. `.cargo/config.toml` sets
  `CMAKE_PROJECT_INCLUDE`, which llama-cpp-sys-2 forwards to llama.cpp's CMake,
  force-including `wipe_free.h` into every llama.cpp/ggml C/C++/ObjC source.
  Cargo does not track that variable: after changing it run
  `cargo clean -p llama-cpp-sys-2` (per target). The patched whisper-rs-sys
  force-includes the same header (`RECORDLESS_WIPE_FREE_H`, tracked). `core/build.rs`
  fails if any llama.cpp/ggml/whisper archive calls `free`/`realloc` directly, and
  `build-xcframework.sh` re-checks the final archive and the operators.
  `Session.new` fails with `MemoryLock` if the native wipe object is not linked.
- Private cloud code runs on a 2-thread tokio runtime inside the core (`nearai::runtime`);
  each FFI call `block_on`s from the caller's thread. TLS is rustls + ring with the
  webpki roots (attested channel and reqwest alike), not the iOS trust store.
- The xcframework's `module.modulemap` autolinks `c++`, Foundation, Metal, MetalKit,
  Accelerate and Security, so the app needs no extra link flags.

### One ggml

whisper-rs-sys and llama-cpp-sys-2 each vendor ggml; two copies in one static library
clash at link time. `vendor/whisper-rs-sys` (wired in by `[patch.crates-io]`) is
whisper-rs-sys 0.15.0 (whisper.cpp 1.8.3) with a new `build.rs`: it compiles only
`whisper.cpp/src/whisper.cpp` (cc, C++17) against the ggml headers that
llama-cpp-sys-2 installs (`DEP_LLAMA_GGML_CMAKE_DIR`/../../include), generates bindings
from those headers, and links nothing but `libwhisper.a`; ggml (CPU + Metal with the
embedded shader library) comes from llama-cpp-sys-2. `llama-cpp-sys-2` and
`llama-cpp-2` are pinned with `=0.1.160` in both `core/Cargo.toml` and the patch (the
patch is only known to build against that ggml, 0.26.0). `core/build.rs` fails unless
`ggml_init` is defined exactly once across llama-cpp-sys-2's archives and not at all in
`libwhisper.a`; `scripts/build-xcframework.sh` checks the final archive the same way.
llama-cpp-2 enables llama-cpp-sys-2's `common` feature, so `libllama-common` and a
small cc-built wrapper are linked too; the wrapper's one direct `free` releases strings
from grammar/chat-template helpers the core never calls.
