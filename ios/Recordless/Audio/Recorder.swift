import AVFoundation
import Foundation
import Observation

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
        case stopped      // session holds a transcript; notes can be generated
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
    var lastError: String?

    /// The stopped session, handed to NotesGenerator. Cleared on discard.
    private(set) var session: Session?

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

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (stoppedAt ?? Date()).timeIntervalSince(startedAt)
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
        pushErrors = 0

        do {
            try capture.start { [weak self] samples in
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
        case .failure(let error): lastError = "stop(): \(describe(error))"
        }
        let stats = try? await offMain { session.speechStats() }
        guard gen == generation else { return }
        speechStats = stats
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
        startedAt = nil
        stoppedAt = nil
        interrupted = false
        level = 0
        phase = .idle
        onWorkFinished?()
    }

    private func startPolling(_ session: Session) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let snap = try? await offMain { (session.progress(), session.speechStats()) }
                guard !Task.isCancelled else { break }
                if let snap {
                    self?.progress = snap.0
                    self?.speechStats = snap.1
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
