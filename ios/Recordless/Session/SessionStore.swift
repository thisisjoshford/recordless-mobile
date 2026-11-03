import Foundation
import Observation

/// One transcribed segment as the UI sees it: a word count, never words.
struct CapturedSegment: Identifiable, Equatable {
    let id: Int
    let wordCount: Int
}

/// Live session state for the Live screen. Holds counts and states only;
/// transcript text never reaches this type.
///
/// For now a mock generator drives it (Milestone 4). Milestone 6 replaces
/// `MockEngine` with `Recorder` / the Rust `Session`, which already reports
/// segments and level; per-segment word counts need a core addition.
@Observable
@MainActor
final class SessionStore {
    enum Status: Equatable { case idle, listening, transcribing, paused, finishing, ended }

    /// What the status pill shows. Transcribing is held for at least
    /// `minTranscribing` so the pill doesn't flicker.
    private(set) var status: Status = .idle
    private(set) var level: Double = 0
    private(set) var segments: [CapturedSegment] = []
    private(set) var wordCount = 0
    var segmentCount: Int { segments.count }

    private var startedAt: Date?
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var endedAt: Date?

    /// Desktop `MIN_TRANSCRIBING_MS`.
    static let minTranscribing: Duration = .milliseconds(400)
    @ObservationIgnored private var transcribingSince: ContinuousClock.Instant?
    @ObservationIgnored private var engine: Task<Void, Never>?

    /// When the current pause began, or nil if not paused.
    var pausedSince: Date? { status == .paused ? pausedAt : nil }

    var isActive: Bool { status != .idle && status != .ended }
    var hasTranscript: Bool { status != .idle }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        let end = endedAt ?? pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedTotal)
    }

    func start() {
        clear()
        startedAt = Date()
        status = .listening
        engine = Task { [weak self] in await self?.runMockEngine() }
    }

    func pause() {
        guard status == .listening || status == .transcribing else { return }
        pausedAt = Date()
        status = .paused
        level = 0
    }

    func resume() {
        guard status == .paused, let pausedAt else { return }
        pausedTotal += Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        status = .listening
    }

    /// Stops listening and drains pending audio. The transcript stays in
    /// memory until `clear()`.
    func end() async {
        guard isActive, status != .finishing else { return }
        if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt); self.pausedAt = nil }
        endedAt = Date()
        status = .finishing
        level = 0
        engine?.cancel()
        try? await Task.sleep(for: .milliseconds(700))      // mock drain
        guard status == .finishing else { return }          // cleared meanwhile
        status = .ended
    }

    /// Releases the transcript: on save, discard, lock and quit.
    func clear() {
        engine?.cancel()
        engine = nil
        status = .idle
        level = 0
        segments = []
        wordCount = 0
        startedAt = nil
        pausedAt = nil
        pausedTotal = 0
        endedAt = nil
        transcribingSince = nil
    }

    // MARK: Mock engine

    private func setTranscribing(_ on: Bool) async {
        if on {
            guard status == .listening else { return }
            transcribingSince = .now
            status = .transcribing
        } else {
            if let since = transcribingSince {
                let remaining = Self.minTranscribing - (ContinuousClock.now - since)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
            }
            transcribingSince = nil
            if status == .transcribing { status = .listening }
        }
    }

    /// Smoothed fake mic level with speech bursts, and a segment every few
    /// seconds.
    private func runMockEngine() async {
        var smoothed = 0.0
        var speaking = true
        var nextToggle = Date().addingTimeInterval(.random(in: 2...5))
        var nextSegment = Date().addingTimeInterval(.random(in: 2.5...4.5))
        var nextID = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if status == .paused { continue }
            let now = Date()
            if now >= nextToggle {
                speaking.toggle()
                nextToggle = now.addingTimeInterval(speaking ? .random(in: 3...7) : .random(in: 0.6...1.8))
            }
            let target = speaking ? Double.random(in: 0.35...0.72) : Double.random(in: 0.02...0.12)
            smoothed += (target - smoothed) * 0.35
            level = smoothed
            if now >= nextSegment, status == .listening {
                await setTranscribing(true)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 150...900)))
                guard !Task.isCancelled, status == .transcribing else { continue }
                let words = Int.random(in: 4...22)
                segments.append(CapturedSegment(id: nextID, wordCount: words))
                nextID += 1
                wordCount += words
                await setTranscribing(false)
                nextSegment = Date().addingTimeInterval(.random(in: 2.5...5))
            }
        }
    }
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
