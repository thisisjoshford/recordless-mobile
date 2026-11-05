import Foundation
import Observation

/// One transcribed segment as the UI sees it. Never words: the core reports
/// only how many segments it has, so the Live screen's blocks are decorative.
struct CapturedSegment: Identifiable, Equatable {
    let id: Int
    /// Blocks drawn for this segment (deterministic per id, not real words).
    var blockCount: Int {
        var h = UInt64(truncatingIfNeeded: id) &* 0x9E3779B97F4A7C15
        h ^= h >> 29
        return 4 + Int(h % 14)
    }
}

/// Live session state for the Live screen, read from `Recorder` (mic capture
/// into memory and on-device Whisper in the core). Counts and states only;
/// transcript text never reaches Swift.
@Observable
@MainActor
final class SessionStore {
    enum Status: Equatable { case idle, starting, listening, transcribing, paused, finishing, ended }

    let recorder: Recorder

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    var status: Status {
        switch recorder.phase {
        case .idle: .idle
        case .loadingModel: .starting
        case .recording:
            recorder.paused ? .paused : recorder.progress?.transcribing == true ? .transcribing : .listening
        case .stopping: .finishing
        case .stopped: .ended
        }
    }

    var level: Double { recorder.paused ? 0 : Double(recorder.level) }
    var segmentCount: Int { Int(recorder.progress?.segments ?? 0) }
    var segments: [CapturedSegment] { (0..<segmentCount).map(CapturedSegment.init(id:)) }

    /// Why the session failed to start or stop, for the Live screen.
    var problem: String? { recorder.stopFailure ?? (recorder.phase == .idle ? recorder.lastError : nil) }

    /// When the current pause began, or nil if not paused.
    var pausedSince: Date? { recorder.pausedAt }

    var isActive: Bool { recorder.isCapturing }
    /// A stopped session whose transcript is still in memory.
    var hasTranscript: Bool { recorder.session != nil }

    func elapsed(at now: Date = Date()) -> TimeInterval { recorder.elapsed(at: now) }

    func start(speechModel: URL, useGpu: Bool) async {
        await recorder.start(speechModel: speechModel, useGpu: useGpu)
    }

    func pause() { recorder.pause() }
    func resume() { recorder.resume() }

    /// Stops listening and drains pending audio. The transcript stays in
    /// memory until `clear()`.
    func end() async { await recorder.stop() }

    /// Releases the transcript: on save, discard, lock and quit.
    func clear() { recorder.discard() }
}

enum DurationFormat {
    /// "12:48" or "1:02:03".
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "32 min", "1 hr 5 min", "<1 min".
    static func minutes(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if t < 60 { return "<1 min" }
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
    }
}
