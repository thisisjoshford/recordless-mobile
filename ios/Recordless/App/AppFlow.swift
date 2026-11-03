import SwiftUI
import Observation

enum MainTab: Hashable { case listen, notes, settings }

/// Navigation and lock state for the designed UI (SPEC.md "Navigation").
/// Drives mock session and notes stores until capture and models are wired
/// in Milestones 6 and 7. Locking always goes through `AppModel.lock()`, so
/// the real notebook closes with the UI.
@Observable
@MainActor
final class AppFlow {
    let app: AppModel
    let session = SessionStore()
    let library = NotesLibrary()

    private(set) var locked = true
    var tab: MainTab = .listen
    var listenPath: [UUID] = []
    var notesPath: [UUID] = []
    var livePresented = false
    var generatePresented = false

    /// The draft whose transcript is still in memory. Edit template is only
    /// offered for this note.
    private(set) var transcriptNoteID: UUID?

    /// Desktop's default (`lib/idle-lock.ts`); desktop lets Settings pick
    /// 5 to 60 minutes. iOS Settings aren't designed yet.
    static let idleLockAfter: TimeInterval = 15 * 60
    /// A paused session left untouched this long is discarded and the
    /// notebook locks, so a forgotten pause can't hold it open.
    static let pausedSessionCap: TimeInterval = 15 * 60
    /// Shown on the Unlock screen after an automatic discard.
    private(set) var lockNotice: String?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        library.onWriteFinished = { [weak self] in
            // A notes run that held off a background lock has ended.
            self?.retryAutomaticLock()
        }
    }

    func canRewrite(_ id: UUID) -> Bool {
        transcriptNoteID == id && session.hasTranscript
    }

    // MARK: Lock

    /// Call after the person has authenticated.
    func didAuthenticate() {
        locked = false
        lockNotice = nil
        noteActivity()
        startIdleTimer()
    }

    func noteActivity() { lastActivity = Date() }

    /// What locking would destroy right now, as desktop and `AppModel` refuse
    /// to lock over it. `nil` means locking is allowed.
    var lockBlocker: String? {
        if session.isActive {
            return "A session is in progress. End it before locking the notebook."
        }
        if library.isWriting {
            return "Notes are being written. Wait for them to finish before locking the notebook."
        }
        if transcriptNoteID != nil || session.hasTranscript {
            return "This session's notes aren't saved yet. Locking clears its transcript, so it can't be rewritten from a template."
        }
        return app.unfinishedWork?.lockRefusal
    }

    /// Lock button and automatic locks. Without `force`, refused (returning
    /// the reason) while there is unfinished work. With `force`, the person
    /// chose to discard it: the session, any notes run and the transcript
    /// are cleared.
    @discardableResult
    func lock(force: Bool = false) -> String? {
        if !force, let blocker = lockBlocker { return blocker }
        if force {
            app.discardSessionAndLock()
        } else if let refusal = app.lock() {
            return refusal.lockRefusal
        }
        library.cancelWriting()
        releaseTranscript()
        livePresented = false       // takes the Generate sheet with it
        listenPath = []
        notesPath = []
        tab = .listen
        locked = true
        idleTask?.cancel()
        return nil
    }

    /// Locks on backgrounding. A refused lock (unfinished work) is retried
    /// when that work ends while still in the background. Listening keeps
    /// running in the background, as in the spike.
    func scenePhaseChanged(_ phase: ScenePhase) {
        inBackground = phase == .background
        if phase == .active {
            // Before touches count as activity: the cap may have passed
            // while the app was suspended.
            enforcePausedCap()
            noteActivity()
        }
        retryAutomaticLock()
    }

    private func retryAutomaticLock() {
        guard inBackground, !locked else { return }
        lock()
    }

    private func startIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !self.locked else { return }
                self.enforcePausedCap()
                guard !self.locked else { return }
                // Refused while work is unfinished; checked again next tick.
                if Date().timeIntervalSince(self.lastActivity) >= Self.idleLockAfter {
                    self.lock()
                }
            }
        }
    }

    private func enforcePausedCap(now: Date = Date()) {
        guard !locked, let since = session.pausedSince else { return }
        if now.timeIntervalSince(max(since, lastActivity)) >= Self.pausedSessionCap {
            lock(force: true)
            lockNotice = "The paused session was discarded after 15 minutes. Its transcript was cleared."
        }
    }

    // MARK: Session

    enum StartBlocker: Equatable { case writing, unsavedDraft }

    /// Starting a new session clears the transcript a draft still holds.
    var startBlocker: StartBlocker? {
        if library.isWriting { return .writing }
        if transcriptNoteID != nil { return .unsavedDraft }
        return nil
    }

    func startListening() {
        guard !library.isWriting else { return }
        releaseTranscript()
        session.start()
        livePresented = true
    }

    func endSession() async {
        await session.end()
        if session.status == .ended { generatePresented = true }
    }

    func generateNotes(on destination: NotesDestination, scrub: Bool) {
        let id = library.startDraft(duration: session.elapsed(), on: destination, scrub: scrub)
        transcriptNoteID = id
        livePresented = false       // takes the Generate sheet with it
        tab = .notes
        notesPath = [id]
    }

    func discardSession() {
        releaseTranscript()
        livePresented = false
        tab = .listen
    }

    /// Called when the Live cover is gone, however it was dismissed.
    func liveDismissed() {
        generatePresented = false
    }

    // MARK: Notes

    func open(_ id: UUID, from tab: MainTab) {
        switch tab {
        case .notes: notesPath.append(id)
        default: listenPath.append(id)
        }
    }

    func rewrite(_ id: UUID, template: String, on destination: NotesDestination, scrub: Bool) {
        guard canRewrite(id) else { return }
        library.rewrite(id, template: template, on: destination, scrub: scrub)
    }

    /// Keeps only the notes and clears the transcript.
    func save(_ note: NoteItem) {
        library.update(note)
        library.save(note.id)
        if transcriptNoteID == note.id { releaseTranscript() }
        AccessibilityNotification.Announcement("Notes saved. The transcript was cleared.").post()
        listenPath = []
        notesPath = []
        tab = .notes
    }

    private func releaseTranscript() {
        session.clear()
        transcriptNoteID = nil
    }

    #if DEBUG
    /// Screenshot hook: the Note screen opens Edit template once.
    var debugTemplate = false

    /// `-ui-screen home|live|generate|note|template|notes` opens a screen on
    /// mock data, for checking layouts against the design.
    func applyDebugScreen() {
        guard let i = CommandLine.arguments.firstIndex(of: "-ui-screen"),
              i + 1 < CommandLine.arguments.count else { return }
        let screen = CommandLine.arguments[i + 1]
        guard screen != "unlock" else { return }
        didAuthenticate()
        switch screen {
        case "notes": tab = .notes
        case "live", "generate":
            startListening()
            if screen == "generate" {
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    await endSession()
                }
            }
        case "note", "template":
            startListening()
            Task {
                try? await Task.sleep(for: .seconds(5))
                await session.end()
                generateNotes(on: .onDevice, scrub: true)
                if screen == "template" { debugTemplate = true }
            }
        default: break
        }
    }
    #endif
}
