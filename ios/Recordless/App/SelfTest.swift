#if DEBUG
import AVFoundation
import os
import Foundation
import UIKit

/// DEBUG-only device self-tests, started by launch arguments, e.g.
///
///     xcrun devicectl device process launch --console --terminate-existing \
///         --device <udid> org.recordless.ios -selftest [-selftest-notes]
///
/// - `-selftest`: pushes the bundled synthetic speech fixture (macOS `say`,
///   generated at build time into Debug builds only; see
///   scripts/make-selftest-fixture.sh) through `Session.push_audio` in 100 ms
///   chunks at real time (`-selftest-speed N` for N x), then stops and prints
///   progress, diagnostics, realtime factor and memory.
///   `-selftest-cpu` runs whisper on the CPU instead of Metal.
/// - `-selftest-notes`: then writes notes on the device from that transcript
///   (downloading and verifying the notes model through ModelStore if
///   needed) and prints load time, tokens/s and peak footprint.
///   `-selftest-notes-cpu` runs the notes model on the CPU.
/// - `-selftest-exit`: quit after printing the result (otherwise the app
///   stays up, notes on the Notes tab).
/// - `-mictest N`: records from the real microphone for N seconds through
///   the normal Recorder path and prints the mic-path counters every 2 s.
///
/// Only counts, timings and sizes are printed: never transcript or notes text.
@MainActor
enum SelfTest {
    static func runIfRequested(_ app: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-selftest") {
            Task { await speechAndNotes(app, args: args) }
        } else if let i = args.firstIndex(of: "-mictest") {
            let seconds = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 20 : 20
            Task { await micTest(app, seconds: seconds) }
        }
    }

    private static func log(_ s: String) {
        print("[selftest] \(s)")
        fflush(stdout)
    }

    /// Prints the result. The app keeps running (so a finished self-test is
    /// not mistaken for a crash) unless `-selftest-exit` was passed.
    private static func finish(_ ok: Bool) async {
        log(ok ? "RESULT PASS" : "RESULT FAIL")
        UIApplication.shared.isIdleTimerDisabled = false
        guard ProcessInfo.processInfo.arguments.contains("-selftest-exit") else { return }
        try? await Task.sleep(for: .milliseconds(500))
        exit(ok ? 0 : 1)
    }

    private static func mb(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }

    /// Waits until `spec` is verified on disk, downloading it if missing.
    private static func ensureModel(_ spec: ModelSpec, store: ModelStore) async -> URL? {
        store.refreshFromDisk()
        var lastPct = -1
        var started = false
        while true {
            switch store.status[spec.id] ?? .missing {
            case .ready:
                return store.fileURL(spec)
            case .missing:
                guard !started else { log("\(spec.id): download disappeared"); return nil }
                log("\(spec.id): not on device, downloading \(mb(spec.bytes)) via ModelStore")
                store.download(spec)
                started = true
            case .failed(let msg):
                log("\(spec.id): failed: \(msg)")
                return nil
            case .downloading(let r, let e):
                let pct = e > 0 ? Int(Double(r) / Double(e) * 100) : 0
                if pct / 10 != lastPct / 10 {
                    log("\(spec.id): downloading \(pct)%")
                    lastPct = pct
                }
            case .verifying:
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func loadFixture() -> [Float]? {
        guard let url = Bundle.main.url(forResource: "selftest", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let ch = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }

    private static func describe(_ p: SessionProgress, _ d: SessionDiagnostics) -> String {
        "segments=\(p.segments) speech_ms=\(p.speechMs) pending_ms=\(p.pendingMs) in_speech=\(p.inSpeech) "
            + "transcribing=\(p.transcribing) incomplete=\(p.incomplete) | samples=\(d.samplesReceived) "
            + "frames=\(d.vadFrames) speech_frames=\(d.vadSpeechFrames) level_db=\(d.levelDbfs) "
            + "noise_db=\(d.noiseFloorDbfs) thr_db=\(d.thresholdDbfs) utt=\(d.utterances) dropped=\(d.utterancesDropped) "
            + "runs=\(d.inferenceRuns) fail=\(d.inferenceFailures) empty=\(d.emptyResults) last_ms=\(d.lastInferenceMs) "
            + "gpu_fallback=\(d.gpuFallback)"
    }

    static func speechAndNotes(_ app: AppModel, args: [String]) async {
        UIApplication.shared.isIdleTimerDisabled = true
        let useGpu = !args.contains("-selftest-cpu")
        let speed = args.firstIndex(of: "-selftest-speed").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 1
        let wantNotes = args.contains("-selftest-notes")
        log("start: core=\(coreVersion()) device_ram=\(mb(ProcessInfo.processInfo.physicalMemory)) "
            + "available=\(mb(UInt64(max(os_proc_available_memory(), 0)))) "
            + "speech_gpu=\(useGpu) speed=\(speed)x notes=\(wantNotes)")

        guard let samples = loadFixture() else {
            log("fixture selftest.wav missing or not 16 kHz mono (Debug build?)")
            return await finish(false)
        }
        log("fixture: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16_000)) s)")
        guard let whisper = await ensureModel(.whisperBase, store: app.models) else { return await finish(false) }

        let t0 = Date()
        let session: Session
        do {
            session = try await offMain { try Session(speechModelPath: whisper.path, useGpu: useGpu) }
        } catch {
            log("Session.new failed: \(recordlessDescribe(error))")
            return await finish(false)
        }
        log("speech model loaded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, footprint \(mb(physFootprintBytes()))")

        // 100 ms chunks, paced like a microphone.
        let chunk = 1600
        let interval = 0.1 / max(speed, 0.1)
        let start = Date()
        var lastLog = Date.distantPast
        for (n, i) in stride(from: 0, to: samples.count, by: chunk).enumerated() {
            let piece = Array(samples[i..<min(i + chunk, samples.count)])
            do { try session.pushAudio(samples: piece) } catch {
                log("push_audio failed: \(recordlessDescribe(error))")
                return await finish(false)
            }
            if Date().timeIntervalSince(lastLog) >= 2 {
                lastLog = Date()
                let p = session.progress(), d = session.diagnostics()
                log("t=\(String(format: "%.1f", Date().timeIntervalSince(start)))s " + describe(p, d))
            }
            let due = start.addingTimeInterval(Double(n + 1) * interval)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        log("pushed all audio in \(String(format: "%.1f", Date().timeIntervalSince(start))) s; stopping")
        let stopped: SessionProgress
        do {
            stopped = try await offMain { try session.stop() }
        } catch {
            log("stop failed: \(recordlessDescribe(error))")
            return await finish(false)
        }
        let d = session.diagnostics(), stats = session.speechStats()
        log("stopped: " + describe(stopped, d))
        log("speech: load_ms=\(stats.loadMs) realtime_factor=\(String(format: "%.1f", stats.realtimeFactor))x "
            + "footprint=\(mb(physFootprintBytes())) peak=\(mb(peakFootprintBytes()))")
        var ok = stopped.segments > 0 && d.inferenceFailures == 0
        log("speech \(ok ? "PASS" : "FAIL"): \(stopped.segments) segments from \(d.utterances) utterances")

        if ok && wantNotes {
            let notesGpu = !args.contains("-selftest-notes-cpu")
            if let llm = await ensureModel(.qwen2B, store: app.models) {
                log("notes: on device via NotesGenerator (the UI path), gpu=\(notesGpu), "
                    + "footprint before \(mb(physFootprintBytes())), available \(mb(UInt64(max(os_proc_available_memory(), 0))))")
                app.selectedTab = .notes
                let poll = Task.detached {
                    var last = ""
                    while !Task.isCancelled {
                        let st = session.notesStatus()
                        let line = "\(st.step ?? "-") (\(st.request)/\(st.requests)) footprint=\(physFootprintBytes() / 1_048_576) MB"
                        if line != last { print("[selftest] notes step: \(line)"); fflush(stdout); last = line }
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                let gen = app.generator
                await gen.generateOnDevice(session: session, model: llm, useGpu: notesGpu)
                poll.cancel()
                if let r = gen.result {
                    let headings = r.markdown.split(separator: "\n").filter { $0.hasPrefix("#") || $0.hasPrefix("**") }.count
                    if let l = r.local {
                        log("notes: model=\(r.modelId) requests=\(r.requests) prompt_tokens=\(r.promptTokens) "
                            + "generated_tokens=\(r.generatedTokens) load_ms=\(l.loadMs) prefill=\(String(format: "%.0f", l.promptTokensPerS)) tok/s "
                            + "generation=\(String(format: "%.1f", l.tokensPerS)) tok/s elapsed_ms=\(r.elapsedMs) "
                            + "ctx=\(l.contextTokens) gpu=\(l.gpu) peak_footprint=\(mb(l.peakFootprintBytes))")
                    }
                    log("notes: \(r.markdown.count) chars, \(headings) heading lines (text not printed); shown on the Notes tab")
                    ok = ok && !r.markdown.isEmpty
                } else {
                    log("notes failed: \(gen.error ?? "?")")
                    ok = false
                }
                // Stay up with the notes rendered, as after a UI run.
                for i in 1...6 {
                    try? await Task.sleep(for: .seconds(5))
                    log("alive \(i * 5)s after notes: footprint=\(mb(physFootprintBytes())) peak=\(mb(peakFootprintBytes()))")
                }
            } else {
                ok = false
            }
        }
        await finish(ok)
    }

    static func micTest(_ app: AppModel, seconds: Double) async {
        UIApplication.shared.isIdleTimerDisabled = true
        guard let whisper = await ensureModel(.whisperBase, store: app.models) else { return await finish(false) }
        log("mic test: \(Int(seconds)) s through the normal Recorder path")
        await app.recorder.start(speechModel: whisper, useGpu: !ProcessInfo.processInfo.arguments.contains("-selftest-cpu"))
        guard app.recorder.phase == .recording else {
            log("recorder did not start: \(app.recorder.lastError ?? "?")")
            return await finish(false)
        }
        try? await Task.sleep(for: .seconds(seconds))
        await app.recorder.stop()
        let segments = app.recorder.progress?.segments ?? 0
        log("mic test: \(segments) segments")
        app.recorder.discard()
        await finish(app.recorder.captureStats.map { $0.framesOut > 0 } ?? false)
    }
}

private func recordlessDescribe(_ error: Error) -> String { describe(error) }
#endif
