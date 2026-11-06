import AVFoundation
import Foundation
import Observation
import os

/// Drives one meeting: Session lifecycle + AudioCapture + ~1 Hz progress polling.
/// Only counts and timings are surfaced. Transcript text never reaches Swift.
@Observable
@MainActor
final class Recorder {
    enum Phase: Equatable {
        case idle
        case loadingModel
        case recording
        case stopping
        case stopped      // session holds a transcript; notes can be generated unless stopFailure is set
    }

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var stoppedAt: Date?
    private(set) var level: Float = 0
    private(set) var interrupted = false
    private(set) var progress: SessionProgress?
    private(set) var speechStats: SpeechStats?
    private(set) var modelLoadMs: UInt64?
    private(set) var pushErrors = 0
    /// Mic path and core counters (no audio, no text), refreshed ~1 Hz while
    /// recording and once after stop. Shown on Bench; printed in DEBUG.
    private(set) var diagnostics: SessionDiagnostics?
    private(set) var captureStats: CaptureStats?
    var lastError: String?
    /// `stop()` failed (a locked-memory failure is a protected-processing
    /// failure: the core discards the transcript, as desktop does). Notes
    /// can't be written from this meeting; this says why.
    private(set) var stopFailure: String?

    /// The stopped session, handed to NotesGenerator. Cleared on discard.
    private(set) var session: Session?

    /// Paused: audio is dropped in memory before it reaches the core.
    private(set) var paused = false
    private(set) var pausedAt: Date?
    /// Paused time so far, excluded from `elapsed`.
    private(set) var pausedTotal: TimeInterval = 0
    private let pauseGate = OSAllocatedUnfairLock(initialState: false)

    private let capture = AudioCapture()
    private var pollTask: Task<Void, Never>?
    /// Bumped by `discard()`. `start()`/`stop()` capture it before each await
    /// and give up if it changed, so a discard during model load or stop is
    /// never overwritten.
    private var generation = 0

    /// Called (on main) whenever capture ends or the session goes away, so the
    /// app can retry a lock that unfinished work blocked.
    @ObservationIgnored var onWorkFinished: (() -> Void)?

    var isCapturing: Bool { phase == .recording || phase == .loadingModel || phase == .stopping }

    var elapsed: TimeInterval { elapsed(at: Date()) }

    /// Listening time, without paused time.
    func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = stoppedAt ?? pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedTotal)
    }

    func pause() {
        guard phase == .recording, !paused else { return }
        pauseGate.withLock { $0 = true }
        paused = true
        pausedAt = Date()
    }

    func resume() {
        guard phase == .recording, paused, let pausedAt else { return }
        pauseGate.withLock { $0 = false }
        pausedTotal += Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        paused = false
    }

    private func resetPause() {
        pauseGate.withLock { $0 = false }
        paused = false
        pausedAt = nil
        pausedTotal = 0
    }

    init() {
        capture.onLevel = { [weak self] v in
            Task { @MainActor in self?.level = v }
        }
        capture.onState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .interrupted: self.interrupted = true
                case .running: self.interrupted = false
                case .failed(let msg):
                    self.interrupted = true
                    self.lastError = "Microphone: \(msg)"
                case .stopped: break
                }
            }
        }
    }

    func start(speechModel: URL, useGpu: Bool) async {
        guard phase == .idle else { return }
        // Claim the recorder before the first await so a second start() is refused.
        phase = .loadingModel
        generation += 1
        let gen = generation
        lastError = nil
        stopFailure = nil
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard gen == generation else { return }    // discarded meanwhile
        guard allowed else {
            lastError = "Microphone access is off. Enable it in Settings > Recordless."
            phase = .idle
            onWorkFinished?()
            return
        }

        let path = speechModel.path
        let t0 = Date()
        let session: Session
        do {
            session = try await offMain { try Session(speechModelPath: path, useGpu: useGpu) }
        } catch {
            guard gen == generation else { return }
            lastError = "Could not load speech model: \(describe(error))"
            phase = .idle
            onWorkFinished?()
            return
        }
        guard gen == generation else {
            // Discarded while the model loaded: drop the new session, never start the mic.
            Task.detached { session.discard() }
            return
        }
        modelLoadMs = UInt64(Date().timeIntervalSince(t0) * 1000)
        self.session = session
        progress = nil
        speechStats = nil
        diagnostics = nil
        captureStats = nil
        pushErrors = 0

        resetPause()
        let gate = pauseGate
        do {
            // Paused audio is dropped in the tap, at capture time, never stored.
            try capture.start(isPaused: { gate.withLock { $0 } }) { [weak self] samples in
                do {
                    try session.pushAudio(samples: samples)
                } catch {
                    Task { @MainActor in
                        self?.pushErrors += 1
                        self?.lastError = "push_audio: \(describe(error))"
                    }
                }
            }
        } catch {
            lastError = "Could not start microphone: \(error.localizedDescription)"
            Task.detached { session.discard() }
            self.session = nil
            phase = .idle
            onWorkFinished?()
            return
        }

        startedAt = Date()
        stoppedAt = nil
        phase = .recording
        startPolling(session)
    }

    func stop() async {
        guard phase == .recording, let session else { return }
        let gen = generation
        phase = .stopping
        if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        paused = false
        stoppedAt = Date()
        capture.stop()          // drains queued pushes
        pollTask?.cancel()
        let stopped: Result<SessionProgress, Error>
        do {
            stopped = .success(try await offMain { try session.stop() })
        } catch {
            stopped = .failure(error)
        }
        guard gen == generation else { return }    // discarded meanwhile: stay idle
        switch stopped {
        case .success(let p): progress = p
        case .failure(let error):
            if case CoreError.MemoryLock = error {
                stopFailure = "Protected memory failed during the session, so the transcript was discarded and notes can't be written from it. Discard this session and start a new one."
            } else {
                stopFailure = "Ending the session failed (\(describe(error))), so notes can't be written from it. Discard this session and start a new one."
            }
            lastError = "stop(): \(describe(error))"
        }
        // After a failure too: whatever the session still reports, not the
        // last live poll.
        let stats = try? await offMain { (session.speechStats(), session.diagnostics(), session.progress()) }
        guard gen == generation else { return }
        speechStats = stats?.0
        diagnostics = stats?.1
        if stopFailure != nil { progress = stats?.2 }
        captureStats = capture.stats
        #if DEBUG
        if let d = diagnostics, let c = captureStats { Self.log(progress, d, c, final: true) }
        #endif
        level = 0
        phase = .stopped
        onWorkFinished?()
    }

    /// Wipes the transcript store. Call when done with this meeting.
    func discard() {
        generation += 1          // invalidates any start()/stop() suspended in an await
        pollTask?.cancel()
        if phase == .recording { capture.stop() }
        if let session {
            Task.detached { session.discard() }
        }
        session = nil
        progress = nil
        stopFailure = nil
        startedAt = nil
        stoppedAt = nil
        interrupted = false
        level = 0
        resetPause()
        phase = .idle
        onWorkFinished?()
    }

    private func startPolling(_ session: Session) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                let snap = try? await offMain { (session.progress(), session.speechStats(), session.diagnostics()) }
                guard !Task.isCancelled else { break }
                if let snap, let self {
                    self.progress = snap.0
                    self.speechStats = snap.1
                    self.diagnostics = snap.2
                    self.captureStats = self.capture.stats
                    #if DEBUG
                    if tick % 2 == 0, let c = self.captureStats { Self.log(snap.0, snap.2, c, final: false) }
                    #endif
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    #if DEBUG
    /// Counts and levels only, never text.
    static func log(_ p: SessionProgress?, _ d: SessionDiagnostics, _ c: CaptureStats, final: Bool) {
        let seg = p.map { "segments=\($0.segments) speech_ms=\($0.speechMs) pending_ms=\($0.pendingMs) in_speech=\($0.inSpeech) transcribing=\($0.transcribing) incomplete=\($0.incomplete)" } ?? "segments=?"
        print("[mic\(final ? " final" : "")] in=\(Int(c.inputSampleRate))Hz/\(c.inputChannels)ch buffers=\(c.buffers) framesIn=\(c.framesIn) framesOut=\(c.framesOut) rate=\(Int(c.convertedRate.rounded())) empty=\(c.emptyConversions) convErr=\(c.conversionErrors) mic_db=\(c.levelDb) | core chunks=\(d.chunksReceived) samples=\(d.samplesReceived) frames=\(d.vadFrames) speechFrames=\(d.vadSpeechFrames) level_db=\(d.levelDbfs) noise_db=\(d.noiseFloorDbfs) thr_db=\(d.thresholdDbfs) utt=\(d.utterances) dropped=\(d.utterancesDropped) runs=\(d.inferenceRuns) fail=\(d.inferenceFailures) empty=\(d.emptyResults) last_ms=\(d.lastInferenceMs) gpu_fallback=\(d.gpuFallback) | \(seg)")
        fflush(stdout)
    }
    #endif
}
