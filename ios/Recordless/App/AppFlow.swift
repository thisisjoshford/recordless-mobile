import SwiftUI
import Observation

enum MainTab: Hashable { case listen, notes, settings }

/// Navigation and lock state for the designed UI (SPEC.md "Navigation"),
/// over the real controllers: `Recorder` (mic into memory, on-device
/// Whisper), `NotesGenerator` and the encrypted `VaultLock`. This is the
/// only lock path; it goes through `AppModel.lock()` so the notebook closes
/// with the UI.
@Observable
@MainActor
final class AppFlow {
    let app: AppModel
    let session: SessionStore
    let library: NotesLibrary

    private(set) var locked = true
    var tab: MainTab = .listen
    var listenPath: [UUID] = []
    var notesPath: [UUID] = []
    var livePresented = false
    var generatePresented = false

    /// The draft whose transcript is still in memory.
    private(set) var transcriptNoteID: UUID?

    /// Desktop's default (`lib/idle-lock.ts`); desktop lets Settings pick
    /// 5 to 60 minutes. iOS Settings aren't designed yet.
    static let idleLockAfter: TimeInterval = 15 * 60
    /// A paused session left untouched this long is discarded and the
    /// notebook locks, so a forgotten pause can't hold it open.
    static let pausedSessionCap: TimeInterval = 15 * 60
    /// Unsaved notes left untouched this long are discarded with the
    /// transcript and the notebook locks, so a forgotten draft can't hold it
    /// open either.
    static let unsavedNotesCap: TimeInterval = 15 * 60
    /// A session still listening with no new speech and no touches this
    /// long is ended (transcript kept), so a forgotten session can't hold
    /// the notebook open. The unsaved-notes cap then applies.
    static let silentSessionCap: TimeInterval = 15 * 60
    /// Speech-segment count at the last check, and when it last grew.
    @ObservationIgnored private var lastSegmentCount = 0
    @ObservationIgnored private var lastSpeechAt = Date()
    /// Shown on the Unlock screen after an automatic discard.
    private(set) var lockNotice: String?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        session = SessionStore(recorder: app.recorder)
        library = NotesLibrary(vault: app.vault, generator: app.generator,
                               recorder: app.recorder, models: app.models)
        // Work that held off a background lock has ended: try again. Hooks
        // can fire from inside lock() itself, so retry on a fresh turn.
        let retry: () -> Void = { [weak self] in
            Task { @MainActor in self?.retryAutomaticLock() }
        }
        // A finished draft restarts the unsaved-notes clock: the person
        // may have waited out a long write without touching the screen.
        library.onWriteFinished = { [weak self] in
            self?.noteActivity()
            retry()
        }
        app.recorder.onWorkFinished = retry
        app.generator.onFinished = retry
        app.vault.onNoteSaved = retry
    }

    // MARK: Unlock

    /// Opens the encrypted notebook with Face ID (passcode fallback), or
    /// creates it on first run. Errors are left in `app.vault.error`.
    func unlock() async {
        let vault = app.vault
        switch vault.state {
        case .noVault: await vault.create()
        case .locked: await vault.unlock()
        case .unlocked, .keyLost: break
        }
        guard vault.state == .unlocked else { return }
        library.memoryOnly = false
        didAuthenticate()
        await library.load()
    }

    #if DEBUG && targetEnvironment(simulator)
    /// The simulator has no Secure Enclave, so no vault: notes stay in memory.
    func unlockWithoutVault() {
        library.memoryOnly = true
        didAuthenticate()
    }
    #endif

    /// The notebook was locked outside this flow (developer tools).
    func vaultStateChanged() {
        guard !locked, !library.memoryOnly, app.vault.state != .unlocked else { return }
        lock(force: true)
    }

    /// Edit template is offered only for the draft whose transcript is
    /// still in memory.
    func canRewrite(_ id: UUID) -> Bool {
        transcriptNoteID == id && session.hasTranscript && library.sessionBlocker == nil
            && library.note(id)?.state == .draft && !library.isWriting && !library.isSaving(id)
    }

    /// Rewrites the draft with the template's instructions.
    func rewrite(_ id: UUID, template: String, on destination: NotesDestination, scrub: Bool) {
        guard canRewrite(id) else { return }
        library.rewrite(id, instructions: template, on: destination, scrub: scrub)
    }

    // MARK: Lock

    /// Call after the person has authenticated.
    private func didAuthenticate() {
        locked = false
        lockNotice = nil
        noteActivity()
        startIdleTimer()
    }

    func noteActivity() { lastActivity = Date() }

    /// What locking would destroy right now, as desktop refuses to lock over
    /// it. `nil` means locking is allowed.
    var lockBlocker: String? {
        if session.isActive {
            return "A session is in progress. End it before locking the notebook."
        }
        if library.isWriting {
            return "Notes are being written. Wait for them to finish before locking the notebook."
        }
        if library.isSaving {
            return "Notes are being saved. Wait for the save to finish before locking the notebook."
        }
        if hasUnsavedWork {
            return "This session's notes aren't saved yet. Locking clears them and the transcript."
        }
        return nil
    }

    /// Unsaved notes, or a transcript notes can still be written from. A
    /// session that captured no speech or failed to stop has nothing to keep,
    /// so it doesn't hold the notebook open.
    private var hasUnsavedWork: Bool {
        library.notes.contains { $0.state != .saved }
            || (session.hasTranscript && library.sessionBlocker == nil)
    }

    /// Lock button and automatic locks. Without `force`, refused (returning
    /// the reason) while there is unfinished work. With `force`, the person
    /// chose to discard it: the session, any notes run, the draft and the
    /// transcript are cleared.
    @discardableResult
    func lock(force: Bool = false) -> String? {
        if !force, let blocker = lockBlocker { return blocker }
        library.cancelWriting()
        // Not blocked but a transcript is held: it has nothing worth keeping
        // (no speech, or the stop failed), so wipe it with the lock.
        if force || session.hasTranscript {
            app.discardSessionAndLock()
        } else if let refusal = app.lock() {
            return refusal.lockRefusal
        }
        transcriptNoteID = nil
        library.clear()
        livePresented = false       // takes the Generate sheet with it
        generatePresented = false
        listenPath = []
        notesPath = []
        tab = .listen
        locked = true
        idleTask?.cancel()
        return nil
    }

    /// Locks on backgrounding. A refused lock (unfinished work) is retried
    /// when that work ends while still in the background. Listening keeps
    /// running in the background.
    func scenePhaseChanged(_ phase: ScenePhase) {
        inBackground = phase == .background
        if phase == .active {
            // Before touches count as activity: the cap may have passed
            // while the app was suspended.
            enforceCaps()
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
                self.enforceCaps()
                guard !self.locked else { return }
                // Refused while work is unfinished; checked again next tick.
                if Date().timeIntervalSince(self.lastActivity) >= Self.idleLockAfter {
                    self.lock()
                }
            }
        }
    }

    /// Discards a forgotten paused or interrupted session, ends a forgotten
    /// silent one, or discards unsaved notes, then locks.
    private func enforceCaps(now: Date = Date()) {
        guard !locked else { return }
        if let since = session.onHoldSince {
            if now.timeIntervalSince(max(since, lastActivity)) >= Self.pausedSessionCap {
                let what = session.pausedSince != nil ? "paused" : "interrupted"
                lock(force: true)
                lockNotice = "The \(what) session was discarded after 15 minutes. Its transcript was cleared."
            }
            return
        }
        if session.status == .listening || session.status == .transcribing {
            if session.segmentCount != lastSegmentCount {
                lastSegmentCount = session.segmentCount
                lastSpeechAt = now
            }
            if now.timeIntervalSince(max(lastSpeechAt, lastActivity)) >= Self.silentSessionCap {
                // Restart the clock so the unsaved-notes cap gives the
                // person another 15 minutes to write notes from it.
                noteActivity()
                Task { await endSession() }
            }
            return
        }
        guard !session.isActive, !library.isWriting, !library.isSaving, hasUnsavedWork else { return }
        if now.timeIntervalSince(lastActivity) >= Self.unsavedNotesCap {
            lock(force: true)
            lockNotice = "Unsaved notes were discarded after 15 minutes without activity. The transcript was cleared."
        }
    }

    // MARK: Session

    enum StartBlocker: Equatable {
        case writing, unsavedDraft
        case noSpeechModel(String)
    }

    var speechModel: ModelSpec? { app.models.ready(.speech).first }

    var startBlocker: StartBlocker? {
        if library.isWriting { return .writing }
        if speechModel == nil {
            if case .downloading = app.models.status[ModelSpec.whisperBase.id] ?? .missing {
                return .noSpeechModel("The speech model is still downloading. Try again when it's done.")
            }
            return .noSpeechModel("Download a speech model first: Settings, Developer tools, Models.")
        }
        if transcriptNoteID != nil || library.notes.contains(where: { $0.state == .draft || $0.state == .failed }) {
            return .unsavedDraft
        }
        return nil
    }

    /// Starts a session. An unsaved draft from the last one is discarded.
    func startListening() {
        guard !library.isWriting, !session.isActive, let spec = speechModel else { return }
        releaseTranscript()
        for note in library.notes where note.state == .draft || note.state == .failed { library.discard(note.id) }
        livePresented = true
        lastSegmentCount = 0
        lastSpeechAt = Date()
        let url = app.models.fileURL(spec)
        let gpu = UserDefaults.standard.bool(forKey: GPUSettings.speechKey)
        Task { await session.start(speechModel: url, useGpu: gpu) }
    }

    func endSession() async {
        await session.end()
        if session.status == .ended { generatePresented = true }
    }

    func generateNotes(on destination: NotesDestination, scrub: Bool) {
        guard let id = library.startDraft(duration: session.elapsed(), on: destination, scrub: scrub) else { return }
        transcriptNoteID = id
        livePresented = false       // takes the Generate sheet with it
        tab = .notes
        notesPath = [id]
    }

    /// Clears the session and any unsaved draft.
    func discardSession() {
        if let id = transcriptNoteID {
            guard !library.isSaving(id) else { return }
            library.discard(id)
        }
        releaseTranscript()
        livePresented = false
        listenPath = []
        notesPath = []
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

    func retry(_ id: UUID, on destination: NotesDestination? = nil, scrub: Bool) {
        guard transcriptNoteID == id else { return }
        library.retry(id, on: destination, scrub: scrub)
    }

    /// Saves to the encrypted notebook, keeping only the notes and clearing
    /// the transcript. Returns an error message if the save failed.
    func save(_ note: NoteItem) async -> String? {
        guard !library.isSaving(note.id) else { return nil }
        library.update(note)
        do {
            guard try await library.save(note.id) else { return nil }
        } catch {
            return "Couldn't save the notes: \(describe(error))"
        }
        // Locked during the save: the notebook is closed and cleared already.
        guard !locked else { return nil }
        if transcriptNoteID == note.id {
            app.recorder.session?.markNotesSaved()
            releaseTranscript()
        }
        AccessibilityNotification.Announcement("Notes saved. The transcript was cleared.").post()
        listenPath = []
        notesPath = []
        tab = .notes
        return nil
    }

    private func releaseTranscript() {
        session.clear()
        app.generator.clear()
        transcriptNoteID = nil
    }

    #if DEBUG
    /// `-ui-screen home|notes` opens a screen with sample notes, for checking
    /// layouts against the design (simulator, no vault).
    func applyDebugScreen() {
        guard let i = CommandLine.arguments.firstIndex(of: "-ui-screen"),
              i + 1 < CommandLine.arguments.count else { return }
        let screen = CommandLine.arguments[i + 1]
        guard screen != "unlock" else { return }
        library.memoryOnly = true
        didAuthenticate()
        library.insertSamples()
        if screen == "notes" { tab = .notes }
        if screen == "writing" {
            tab = .notes
            notesPath = [library.insertWritingSample()]
        }
    }
    #endif
}
