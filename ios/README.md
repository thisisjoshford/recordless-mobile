# Recordless iOS (phase-0 spike)

SwiftUI app that proves capture → on-device transcription → scrubbed notes written
on the device (llama.cpp, the default) or by a private cloud model in a verified
secure enclave (NEAR AI TEE), and measures speed and memory. Audio stays in memory; the transcript never crosses into Swift (see
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
3. On the device: **Models** → download Whisper base.en (and/or small.en) and the
   notes model Qwen 3.5 2B (~1.3 GB; 4B is offered on 8 GB devices). Downloads
   continue in the background.
4. **Record** → Start, talk, lock the screen if you like (background audio keeps
   capture running), Stop.
5. **Notes** → Where: **On this device** (default; pick the model; CPU by default,
   GPU optional) → Write notes. Or **Private cloud** → unlock the notebook, enter an activation code (redeemed with the
   credit service compiled in by `build-xcframework.sh`; it defaults to the same
   Worker as desktop, override with `RECORDLESS_TRIAL_URL`), pick a model, choose
   what to scrub, Write notes. Shows each verification check, elapsed time and token
   counts, then the notes. Save to vault (creates the notebook on first use). There is no passphrase: the
   notebook unlocks with Face ID, or the device passcode as fallback. A device
   passcode is required; without one the app refuses to create a notebook.
   If Write notes is disabled, the reason is shown under it.
6. **Bench** → Settings has the GPU (Metal) switches for speech and on-device
   notes. Both are **off by default**, as on desktop: memory the CPU used is wiped
   when freed, GPU memory can't be. A GPU run that fails (iOS refuses GPU work in
   the background) moves to the CPU. Bench also shows live `phys_footprint`, peak footprint, the speech realtime
   factor, the microphone path (input format, converted rate, levels, VAD and
   whisper counters: where audio stops if no segments appear) and the notes run
   (load ms, prefill and generation tokens/s, peak footprint).

## Device self-test (Debug builds)

Debug builds bundle a synthetic speech fixture (generated at build time by
`scripts/make-selftest-fixture.sh` with macOS `say`; Release builds don't) and
accept launch arguments (`Recordless/App/SelfTest.swift`). Pass app arguments
after `--`:

```sh
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
  org.recordless.ios -- -selftest -selftest-notes
```

`-selftest` streams the fixture through `Session.push_audio` in real time and prints
progress, diagnostics, the realtime factor and memory; `-selftest-notes` then writes
notes on the device (downloading the model via ModelStore if needed) and prints load
time, tokens/s and peak footprint. Both run on the CPU (the app default);
`-selftest-gpu` and `-selftest-notes-gpu` use Metal instead. `-selftest-speed N`, and `-mictest N` (real microphone for N seconds, mic-path
counters every 2 s) are also available. Only counts and timings are printed. The app
keeps running after `RESULT PASS/FAIL` (notes shown on the Notes tab) unless
`-selftest-exit` is passed.

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
