# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this repo is

**recordless-mobile** is the iPhone app for **Recordless**: meeting notes without the recording. It is a native SwiftUI app over a shared Rust core (`core/`, exposed to Swift through UniFFI). The desktop app (Tauri + Rust + Next.js) lives in `../recordless`; the two are separate products with separate notebooks and no sync.

Read before changing behaviour:

1. This file: the rules, the layout and how to build.
2. `CONFIDENTIAL-ios.md`: the iOS privacy design and where it differs from desktop.
3. `docs/core-ffi.md`: the Rust/Swift boundary (the transcript never crosses into Swift).
4. `docs/design/SPEC.md`, `docs/design/tokens.json`, `docs/design/screens/*.dc.html`: every screen, state and token. The inline `style` values in the `.dc.html` files are the spec; use them as reference, never ship them.
5. `../recordless/CLAUDE.md` and `../recordless/CONFIDENTIAL.md`: the desktop privacy design this app keeps.

Human-facing design handoff: https://claude.ai/artifact/FdrAZxQRxFytQwnubgxY79
Design canvas: https://claude.ai/artifact/9TefXtbvRnyupN6JW2VXr7

## Hard rules (never break these)

Breaking any of these is a bug, not a trade-off. If a request or library would break one, stop and ask.

- **No audio on disk.** Capture and process audio in memory only. No recording files, no checkpoints, no playback, no import, no re-transcription. Paused audio is dropped in the mic tap, before it is queued.
- **No transcript text in the UI, on disk, or in logs.** Transcript segments live in the Rust core only and are zeroed when released. Swift and the UI get counts (segments) and states, never words. Logs carry counts only. Search covers generated notes only.
- **Transcript lifetime.** The in-memory transcript is cleared when the person saves notes, discards the session, locks the app, or the app quits.
- **Encrypted notebook.** Notes are stored encrypted on device. There is no passphrase: a random vault key is wrapped by a Secure Enclave key and unlocked with Face ID or the device passcode, on this device only. Auto-lock when idle, and nothing may hold the notebook open indefinitely (see "Locking" below).
- **Notes models.** On-device model (llama.cpp) by default. The only remote option is the private cloud model in a NEAR AI secure enclave, used only after TEE attestation verifies on the same TLS connection that carries the prompt. Add no other remote providers or endpoints. The existing ones, all listed in `CONFIDENTIAL-ios.md` "Network": Hugging Face model downloads (pinned commit + SHA-256); NEAR AI host list, model catalogue and TEE hosts; Intel PCS, NVIDIA NRAS and raw.githubusercontent.com (attestation only); and the Recordless credit service for activation codes (never receives content; the NEAR AI key is stored and used only in the core and never returned to Swift).
- **Scrubbing.** Identifier scrubbing is on by default before text reaches a notes model: emails, phones, links and ID/card/account numbers are replaced by pattern (`core/src/redact.rs`); names can't be matched by pattern, so the prompt tells the model to refer to people by role. It covers Edit template instructions too (`core/src/prompt.rs`). Scrubbing less than everything requires an explicit confirmation the person cannot skip.
- **No telemetry.** No analytics SDKs, crash reporters that upload content, or tracking.
- **Wording.** Say "listening" and "session", never "recording" or "record", in any user-visible text, Developer tools included. The approved tagline "Meeting notes without the recording." is the one exception.
- **Red is the logo's color only** (`Theme.brandDot` #E5362F). Never use system `.red`. Live states use navy and info (`Theme.primary`, `Theme.info`); errors and delete use the muted brick `Theme.destructive` #A8413A.

## Stack

- Swift + SwiftUI, **iOS 26**, iPhone only (390 x 844 pt design frame). Bundle id **`org.recordless.ios`**.
- XcodeGen: `ios/project.yml` generates `ios/Recordless.xcodeproj`.
- Rust core `recordless_core` (`core/`) built into `ios/Frameworks/RecordlessCore.xcframework`, with Swift bindings in `ios/Generated/recordless_core.swift`. The xcodeproj, `Frameworks/` and `Generated/` are generated and gitignored.
- Speech: Whisper on device in the core. Notes: llama.cpp on device (Qwen 3.5 2B by default), or the NEAR AI private cloud.
- AVAudioEngine for mic capture into memory. Microphone only: iOS can't capture other apps' audio.
- Fonts: Source Sans 3 (400, 600, 700) for UI, Instrument Serif 400 for the wordmark only. Light mode only.

## Layout

- `core/src/`: Rust core. `session.rs` (capture session, stop, lock/release, discard), `store.rs` (the mlocked in-memory transcript store, scrubbed on the way out; the most privacy-sensitive file), `vad.rs` (voice activity), `notes.rs` (private cloud notes run), `nearai/` (TEE attestation on the request's connection: `remote.rs`, `evidence.rs`, `channel.rs`; activation codes: `activation.rs`), `local_notes.rs` (on-device notes), `prompt.rs` (notes prompt, scrubbing of style instructions, no-verbatim rule), `redact.rs` (identifier scrubbing), `vault*` (encrypted notebook), `alloc.rs`/`secure.rs`/`native_wipe.rs` and `core/native/` (memory wiped on free, including whisper.cpp, llama.cpp and ggml allocations; `core/build.rs` checks the wiring), `memory.rs` (memory footprint measurement).
- `ios/Recordless/App/`: `AppFlow` (navigation, unlock, the only lock path, idle timer and caps), `AppModel` (owns the controllers), `NotesGenerator`, `PrivacyShield.swift` (`PrivacyShield` covers windows when the app isn't active; `ActivityMonitor` reports touches for the idle lock), `SelfTest` (device self-test).
- `ios/Recordless/Vault/VaultLock.swift`: notebook states and Secure Enclave key wrapping (Face ID / passcode).
- `ios/Recordless/Models/ModelStore.swift`: pinned model downloads (background URLSession).
- `ios/Recordless/Audio/`: `Recorder` (phases, pause, interruption) and `AudioCapture` (AVAudioEngine tap, pause gate).
- `ios/Recordless/Session/`: `SessionStore` (Live screen state from `Recorder`), `NotesLibrary` (notes in memory, writing, rewrite, save, load), with the `NoteMarkdown` enum in the same file (parse/render of the core's notes format).
- `ios/Recordless/Screens/`: the designed screens (Unlock, Home, Live session, Generate notes sheet, Note, Edit template sheet, Notes tab).
- `ios/Recordless/Views/`: Developer tools (Models, Capture, Notes, Notebook, Bench), reachable from Settings. Model downloads live here; onboarding isn't built.
- `ios/Recordless/Design/`: `Theme` tokens (names as in tokens.json) and reusable views.

## Build and run

```sh
# Rust core -> xcframework + Swift bindings (re-run whenever core/ changes; ~20 s)
./scripts/build-xcframework.sh

# Core tests (the package is recordless_core)
cargo test --manifest-path core/Cargo.toml --lib

# Regenerate the Xcode project (when project.yml changes or files are added)
cd ios && xcodegen generate

# Simulator build
xcodebuild -project Recordless.xcodeproj -scheme Recordless \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/dd-sim build

# Device build, install, launch (test phone "George", iPhone 14 Pro, team U7Z273Y6XY)
xcodebuild -project Recordless.xcodeproj -scheme Recordless \
  -destination 'id=00008120-00094C6026F3C01E' -derivedDataPath build/dd \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=U7Z273Y6XY build
xcrun devicectl device install app --device 00008120-00094C6026F3C01E build/dd/Build/Products/Debug-iphoneos/Recordless.app
xcrun devicectl device process launch --device 00008120-00094C6026F3C01E org.recordless.ios
```

Launch fails with `BSErrorCodeDescription = Locked` when the phone is locked; the install still succeeded.

`build-xcframework.sh` builds the core for iOS 17 (`IPHONEOS_DEPLOYMENT_TARGET`) while the app targets 26; that's fine, as the app's target is the floor.

**Device self-test (Debug builds only):** launch arguments `-selftest` (streams the bundled audio fixture), `-selftest-notes`, `-mictest N` (real microphone for N seconds) and `-selftest-exit`; more options in `ios/README.md`.

**Simulator:** there is no Secure Enclave, so no notebook. DEBUG simulator builds offer "Continue without a notebook" (notes stay in memory). `-ui-screen home|notes|writing` opens a screen with sample notes for checking layouts against the design; sample data is DEBUG-only and never ships.

## Behaviour worth knowing

- **Flow:** Start listening → pause/resume → End session → Generate notes sheet (on device or private cloud, scrubbing on) → draft → edit or Edit template (rewrites with the person's style instructions while the transcript is in memory) → Save. Saving stores the notes and clears the transcript. Saved notes are read-only (the vault can't update or delete a note).
- **Background:** listening continues in the background and with the screen locked (`UIBackgroundModes: audio`). Backgrounding locks the notebook unless that would lose work (a session, a notes run or save, unsaved notes); the lock is retried when the work ends, and the Locking caps still apply.
- **Locking** (`AppFlow`): manual, idle (15 min), and on backgrounding, refused while there is work to lose and retried when that work ends. Caps keep anything from holding the notebook open: a paused or interrupted session is discarded after 15 min; a session still listening with no new speech and no touches for 15 min is ended; unsaved notes are discarded after 15 min without activity. A finished draft and typing count as activity.
- **Notes format:** the core writes `# Title`, then `**Section**` headers (Meeting Summary, Discussion Highlights, Decisions and Agreements, Open Questions, Next Steps) with paragraphs and `- ` items. `NoteMarkdown.render` escapes paragraph lines that look like structure so saved notes read back as written; `render(forExport: true)` (Copy, Share) doesn't. Saved copies add a `<!-- recordless duration=… on=… -->` metadata line (length, where written), read back and never shown.
- **Copy:** read-only note text is never selectable (don't add `.textSelection` to notes anywhere, Developer tools included). The "Copy notes" button copies on this device only (no Universal Clipboard), expiring after 3 minutes. Draft fields are editable `TextField`s, so the system Copy menu still works there, without those limits.

## Out of scope (don't design or build without asking)

Settings contents (beyond Developer tools), onboarding (mic permission, model download), iPad layout, notes sync, Live Activities / Dynamic Island, blocking third-party keyboards.

## Conventions

- Copy in brackets in the design, like `[Meeting title]`, is placeholder data. Never hard-code it.
- Use token names from tokens.json via `Theme`; no raw hex in views.
- Touch targets at least 44 pt. Support Dynamic Type for body text and Reduce Motion.
- Use real controls (`Button`, `Toggle`, `TextField`) with accessibility labels on icon-only buttons.
- Don't draw a fake status bar or home indicator.
- Workflow the owner uses: build → install on the phone → sub-agent review → fix → repeat. Merge PRs with merge commits. With stacked PRs, retarget the child to `main` before deleting the parent's branch, or GitHub closes the child.
- zsh: brace variables before `:` (`"${SHA}:refs/..."`); `$SHA:r` is a zsh modifier.
