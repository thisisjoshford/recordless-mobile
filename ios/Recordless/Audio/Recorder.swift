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
        lastError = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone access is off. Enable it in Settings > Recordless."
            return
        }

        phase = .loadingModel
        let path = speechModel.path
        let t0 = Date()
        let session: Session
        do {
            session = try await offMain { try Session(speechModelPath: path, useGpu: useGpu) }
        } catch {
            lastError = "Could not load speech model: \(describe(error))"
            phase = .idle
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
            session.discard()
            self.session = nil
            phase = .idle
            return
        }

        startedAt = Date()
        stoppedAt = nil
        phase = .recording
        startPolling(session)
    }

    func stop() async {
        guard phase == .recording, let session else { return }
        phase = .stopping
        stoppedAt = Date()
        capture.stop()          // drains queued pushes
        pollTask?.cancel()
        do {
            progress = try await offMain { try session.stop() }
        } catch {
            lastError = "stop(): \(describe(error))"
        }
        speechStats = try? await offMain { session.speechStats() }
        level = 0
        phase = .stopped
    }

    /// Wipes the transcript store. Call when done with this meeting.
    func discard() {
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
        phase = .idle
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
