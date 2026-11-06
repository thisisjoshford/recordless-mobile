import Foundation
import Observation

/// Owns the long-lived controllers. Everything here is main-actor state; the
/// blocking Rust calls are always made from detached tasks.
@Observable
@MainActor
final class AppModel {
    let models = ModelStore.shared
    let recorder = Recorder()
    let vault = VaultLock()
    let generator = NotesGenerator()
    var selectedTab: AppTab = .models

    // Automatic locks (background, idle) and their retries live in
    // `AppFlow`, which calls `lock()` / `discardSessionAndLock()` here.

    /// What locking would destroy right now (desktop CONFIDENTIAL.md step 7):
    /// a recording, a notes request in flight, or a transcript with no saved
    /// notes. `nil` means locking is allowed.
    var unfinishedWork: UnfinishedWork? {
        if recorder.isCapturing { return .recording }
        if generator.running { return .generatingNotes }
        return recorder.session?.unfinishedWork()
    }

    /// Closes the notebook. Refused (returning the reason) while there is
    /// unfinished work. Otherwise wipes any held transcript (one kept only for
    /// regeneration), clears the generated notes shown on screen, and closes
    /// the notebook.
    @discardableResult
    func lock() -> UnfinishedWork? {
        if let work = unfinishedWork { return work }
        if let session = recorder.session {
            // Atomic in the core: refuses if a request started meanwhile.
            if let work = session.releaseForLock() { return work }
            recorder.discard()
        }
        generator.clear()
        vault.lock()
        return nil
    }

    /// Explicit "discard session": always allowed, whatever is unfinished.
    func discardSessionAndLock() {
        recorder.discard()      // cancels a notes request in flight and wipes the transcript
        generator.clear()
        vault.lock()
    }
}

extension UnfinishedWork {
    /// Why the notebook did not lock.
    var lockRefusal: String {
        switch self {
        case .recording:
            "A session is in progress. End it before locking the notebook."
        case .generatingNotes:
            "Notes are being written. Wait for them to finish, or cancel, before locking the notebook."
        case .unsavedTranscript:
            "This session has no saved notes yet. Locking would clear its transcript. Save the notes, or discard the session, first."
        }
    }
}

enum Format {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: b), countStyle: .memory)
    }
    static func duration(ms: UInt64) -> String {
        duration(seconds: Double(ms) / 1000)
    }
    static func duration(seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// GPU (Metal) switches for speech and on-device notes. Both are off by
/// default, as on desktop: the CPU's memory is wiped on free, GPU memory
/// can't be. (New keys, so installs that had the old GPU default start on
/// the CPU.)
enum GPUSettings {
    static let speechKey = "settings.speechUseGpu"
    static let notesKey = "settings.notesUseGpu"
}

/// Small helper to run a blocking core call off the main actor.
func offMain<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

func describe(_ error: Error) -> String {
    if let e = error as? CoreError { return "\(e)" }
    return error.localizedDescription
}

struct AppError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
