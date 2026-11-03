# Recordless iOS (phase-0 spike)

SwiftUI app that proves capture → on-device transcription → scrubbed notes from a
private cloud model in a verified secure enclave (NEAR AI TEE), and measures speed and
memory. Audio stays in memory; the transcript never crosses into Swift (see
`../docs/core-ffi.md` and `../CONFIDENTIAL-ios.md`).

## Build

Requirements: Xcode 26+, Rust with the `aarch64-apple-ios` and
`aarch64-apple-ios-sim` targets, XcodeGen (`brew install xcodegen`).

```sh
# 1. Rust core -> ios/Frameworks/RecordlessCore.xcframework + ios/Generated/*.swift
./scripts/build-xcframework.sh

# 2. Generate the Xcode project
cd ios && xcodegen generate

# 3. Build (simulator) or open in Xcode
xcodebuild -project Recordless.xcodeproj -scheme Recordless \
  -destination 'generic/platform=iOS Simulator' build
open Recordless.xcodeproj
```

Re-run step 1 whenever `core/` changes and step 2 whenever `project.yml` changes
or files are added. `Recordless.xcodeproj`, `Frameworks/` and `Generated/` are
generated and gitignored.

## Run on a device

1. In Xcode, select the **Recordless** target → Signing & Capabilities, pick your
   team (or set `DEVELOPMENT_TEAM` in `project.yml`). Automatic signing is on.
   The `increased-memory-limit` entitlement requires a paid developer team.
2. Choose your iPhone as the run destination and Run (Release is more
   representative for benchmarks: Product → Scheme → Edit Scheme → Run → Release).
3. On the device: **Models** → download Whisper base.en (and/or small.en).
   Downloads continue in the background.
4. **Record** → Start, talk, lock the screen if you like (background audio keeps
   capture running), Stop.
5. **Notes** → unlock the notebook, enter an activation code (the core needs
   `RECORDLESS_TRIAL_URL` set when `build-xcframework.sh` ran), pick a model, choose
   what to scrub, Write notes. Shows each verification check, elapsed time and token
   counts, then the notes. Save to vault (creates the notebook on first use). There is no passphrase: the
   notebook unlocks with Face ID, or the device passcode as fallback. A device
   passcode is required; without one the app refuses to create a notebook.
6. **Bench** shows live `phys_footprint`, peak footprint and the speech
   realtime factor.

Face ID and the Secure Enclave are not available in the simulator, so the
notebook can't be created or unlocked there (the gate explains why). Test it on a
device. If the notebook's key disappears (iOS deletes it when the passcode is
turned off), the app says the notebook can't be opened on this device and offers
to start a new one, moving the old one to `vault-set-aside-<time>`.

## Layout

- `Recordless/App` – app entry, privacy overlay, scene-lock handling, notes generator
- `Recordless/Audio` – `AudioCapture` (AVAudioEngine → 16 kHz mono f32), `Recorder`
- `Recordless/Models` – `ModelStore` (background URLSession downloads)
- `Recordless/Vault` – `VaultLock` (random vault key wrapped by a Secure Enclave key; Face ID / passcode unlock)
- `Recordless/Views` – spike screens
