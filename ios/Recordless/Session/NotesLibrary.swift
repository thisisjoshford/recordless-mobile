import Foundation
import Observation

enum NotesDestination: String, CaseIterable, Identifiable {
    case onDevice, privateCloud
    var id: String { rawValue }
}

/// One section of generated notes ("Meeting Summary", "Next Steps", ...):
/// a paragraph, list items, or both.
struct NoteSection: Identifiable, Equatable {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// nil for a plain bullet, else a checkbox.
        var done: Bool?
    }

    let id = UUID()
    var title: String
    var text: String = ""
    var items: [Item] = []

    /// Sections whose items are to-dos get checkboxes.
    static func isActionSection(_ title: String) -> Bool {
        let t = title.lowercased()
        return t.contains("next step") || t.contains("action")
    }
}

/// A note as the UI sees it. Generated notes only; never transcript text.
struct NoteItem: Identifiable, Equatable {
    enum State: Equatable { case writing, failed, draft, saved }

    let id: UUID
    /// The note's id in the encrypted notebook, once saved.
    var vaultID: String?
    var title: String
    let createdAt: Date
    /// 0 when unknown (notes saved by the developer tools).
    let duration: TimeInterval
    var state: State
    var writtenOn: NotesDestination?
    var sections: [NoteSection] = []
    /// Why writing failed (state `.failed`), or why a rewrite failed (the
    /// draft is kept).
    var error: String?

    var displayTitle: String { title.isEmpty ? "Untitled session" : title }

    var firstSummaryLine: String {
        for section in sections {
            if let line = section.text.split(whereSeparator: \.isNewline).first {
                return line.replacingOccurrences(of: "**", with: "")
            }
            if let item = section.items.first { return item.text.replacingOccurrences(of: "**", with: "") }
        }
        return ""
    }

    /// Generated notes the Notes search may match. Never a transcript.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let parts = [title] + sections.flatMap { [$0.title, $0.text] + $0.items.map(\.text) }
        return parts.joined(separator: "\n").localizedStandardContains(q)
    }
}

/// The notebook: saved notes from the encrypted vault, plus the draft being
/// written or reviewed (in memory only until Save). Notes are written by
/// `NotesGenerator` from the transcript `Recorder` holds in the core.
@Observable
@MainActor
final class NotesLibrary {
    private(set) var notes: [NoteItem] = []
    private(set) var loadError: String?
    /// DEBUG simulator only (no Secure Enclave, so no vault): saved notes stay
    /// in memory and are gone on lock.
    var memoryOnly = false

    let vault: VaultLock
    let generator: NotesGenerator
    let recorder: Recorder
    let models: ModelStore

    /// Called when a notes run ends (finished, failed or cancelled).
    @ObservationIgnored var onWriteFinished: (() -> Void)?
    @ObservationIgnored private var writer: Task<Void, Never>?
    /// The draft a rewrite replaces, restored if the rewrite fails or is
    /// cancelled.
    @ObservationIgnored private var beforeRewrite: NoteItem?

    init(vault: VaultLock, generator: NotesGenerator, recorder: Recorder, models: ModelStore) {
        self.vault = vault
        self.generator = generator
        self.recorder = recorder
        self.models = models
    }

    var isWriting: Bool { generator.running || notes.contains { $0.state == .writing } }
    /// The core's current step label ("Summary chunk 2 of 3", ...).
    var writingStep: String? { generator.status?.step }

    func note(_ id: UUID) -> NoteItem? { notes.first { $0.id == id } }

    func update(_ note: NoteItem) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i] = note
    }

    // MARK: Notebook

    /// Reads every saved note (notes only, decrypted into memory) after unlock.
    func load() async {
        guard !memoryOnly else { return }
        do {
            let list = try await vault.listNotes()
            var loaded: [NoteItem] = []
            for summary in list {
                let markdown = try await vault.readNote(id: summary.id)
                let parsed = NoteMarkdown.parse(markdown)
                loaded.append(NoteItem(
                    id: UUID(), vaultID: summary.id,
                    title: parsed.title.isEmpty ? summary.title : parsed.title,
                    createdAt: Date(timeIntervalSince1970: Double(summary.createdAtMs) / 1000),
                    duration: parsed.duration, state: .saved, writtenOn: parsed.writtenOn,
                    sections: parsed.sections))
            }
            // Keep a draft that appeared while loading.
            notes = notes.filter { $0.state != .saved } + loaded
            loadError = nil
        } catch {
            loadError = "Couldn't read the notebook: \(describe(error))"
        }
    }

    /// Drops every note from memory (lock).
    func clear() {
        cancelWriting()
        notes = []
        loadError = nil
    }

    // MARK: Writing

    /// Why notes can't be written from the current session, or nil.
    var sessionBlocker: String? {
        if let failure = recorder.stopFailure { return failure }
        guard recorder.session != nil else { return "This session's transcript is gone." }
        if (recorder.progress?.segments ?? 0) == 0 {
            return "No speech was captured in this session, so there is nothing to write notes from."
        }
        return nil
    }

    var localModel: ModelSpec? {
        let ready = models.ready(.notes)
        return ready.first { $0.id == generator.localModelID } ?? ready.first
    }

    /// Why notes can't be written on this iPhone, or nil.
    var onDeviceBlocker: String? {
        guard localModel == nil else { return nil }
        if case .downloading = models.status[ModelSpec.qwen2B.id] ?? .missing {
            return "The notes model is still downloading."
        }
        return "Download a notes model first: Settings, Developer tools, Models."
    }

    enum CloudReadiness: Equatable { case checking, ready, unavailable(String) }

    /// Whether the private cloud can take a request. Attestation itself is
    /// checked by the core on the connection that carries the request;
    /// nothing is sent unless it passes.
    var cloudReadiness: CloudReadiness {
        guard vault.vault != nil else { return .unavailable("The private cloud needs the encrypted notebook.") }
        guard let credit = generator.credit else {
            if let e = generator.creditError { return .unavailable("Couldn't check private cloud credit: \(e)") }
            return .checking
        }
        if !credit.active { return .unavailable("Not activated. Add an activation code in Settings, Developer tools, Notes.") }
        if credit.creditUsedUp { return .unavailable("Private cloud credit is used up.") }
        return .ready
    }

    func refreshCloud() async {
        if let v = vault.vault { await generator.refresh(vault: v) }
    }

    /// Starts writing notes for the stopped session. Returns the new note's
    /// id. `scrub` is the person's confirmed scrubbing choice.
    func startDraft(duration: TimeInterval, on destination: NotesDestination, scrub: Bool) -> UUID? {
        guard !isWriting else { return nil }
        let note = NoteItem(id: UUID(), title: "", createdAt: Date(), duration: duration,
                            state: .writing, writtenOn: destination)
        notes.insert(note, at: 0)
        write(note.id, on: destination, scrub: scrub)
        return note.id
    }

    /// Writes a failed note again (the core keeps the transcript on failure).
    func retry(_ id: UUID, scrub: Bool) {
        guard !isWriting, var note = note(id), note.state == .failed,
              let destination = note.writtenOn else { return }
        note.state = .writing
        note.error = nil
        update(note)
        write(id, on: destination, scrub: scrub)
    }

    /// Rewrites a draft with the person's style instructions (Edit
    /// template), while the transcript is still in memory. A failed rewrite
    /// keeps the previous draft.
    func rewrite(_ id: UUID, instructions: String, on destination: NotesDestination, scrub: Bool) {
        guard !isWriting, var note = note(id), note.state == .draft else { return }
        beforeRewrite = note
        note.state = .writing
        note.writtenOn = destination
        note.error = nil
        update(note)
        write(id, on: destination, scrub: scrub, instructions: instructions)
    }

    private func write(_ id: UUID, on destination: NotesDestination, scrub: Bool, instructions: String? = nil) {
        writer = Task { [weak self] in
            guard let self else { return }
            let failure = await self.runGenerator(on: destination, scrub: scrub, instructions: instructions)
            defer { self.onWriteFinished?() }
            let previous = self.beforeRewrite
            self.beforeRewrite = nil
            // Discarded or locked meanwhile: the note is already gone.
            guard var note = self.note(id), note.state == .writing else { return }
            if let markdown = failure == nil ? self.generator.result?.markdown : nil {
                let parsed = NoteMarkdown.parse(markdown)
                note.title = parsed.title
                note.sections = parsed.sections
                note.state = .draft
            } else if var previous {
                previous.error = "The rewrite didn't finish, so your draft is unchanged. \(failure ?? self.generator.error ?? "")"
                note = previous
            } else {
                note.state = .failed
                note.error = failure ?? self.generator.error ?? "Notes couldn't be written."
            }
            self.generator.clear()      // the notes now live in the draft only
            self.update(note)
        }
    }

    /// Runs the generator; returns why it couldn't start, if it couldn't.
    private func runGenerator(on destination: NotesDestination, scrub: Bool, instructions: String?) async -> String? {
        if let blocker = sessionBlocker { return blocker }
        guard let session = recorder.session else { return "This session's transcript is gone." }
        generator.prepare(for: session)
        generator.scrubEmails = scrub
        generator.scrubPhones = scrub
        generator.scrubUrls = scrub
        generator.scrubNumbers = scrub
        generator.scrubNames = scrub
        switch destination {
        case .onDevice:
            if let blocker = onDeviceBlocker { return blocker }
            guard let spec = localModel else { return onDeviceBlocker }
            await generator.generateOnDevice(session: session, model: models.fileURL(spec),
                                             useGpu: generator.localUseGpu, instructions: instructions)
        case .privateCloud:
            if case .unavailable(let reason) = cloudReadiness { return reason }
            guard let v = vault.vault else { return "The private cloud needs the encrypted notebook." }
            await generator.generate(session: session, vault: v, instructions: instructions)
        }
        return nil
    }

    /// Stops the notes run (discard, lock): a first run's note is removed,
    /// a rewrite falls back to its previous draft.
    func cancelWriting() {
        if generator.running, let session = recorder.session { generator.cancel(session: session) }
        writer?.cancel()
        writer = nil
        let hadWriting = notes.contains { $0.state == .writing }
        if let previous = beforeRewrite, note(previous.id)?.state == .writing { update(previous) }
        beforeRewrite = nil
        notes.removeAll { $0.state == .writing }
        if hadWriting { onWriteFinished?() }
    }

    /// Removes an unsaved draft or failed note.
    func discard(_ id: UUID) {
        guard let note = note(id), note.state != .saved else { return }
        if note.state == .writing { cancelWriting() }
        notes.removeAll { $0.id == id }
    }

    // MARK: Saving

    /// Saves a draft to the encrypted notebook. Throws if the vault refuses.
    func save(_ id: UUID) async throws {
        guard var note = note(id), note.state == .draft else { return }
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Session \(note.createdAt.formatted(date: .abbreviated, time: .shortened))"
            : note.title
        if memoryOnly {
            note.vaultID = UUID().uuidString
        } else {
            note.vaultID = try await vault.saveNote(title: title, markdown: NoteMarkdown.render(note, metadata: true))
        }
        note.title = title
        note.state = .saved
        update(note)
    }

    #if DEBUG
    /// Screenshot hook: sample notes in memory, never saved.
    func insertSamples() { notes = MockNotes.sample() + notes }

    /// Screenshot hook: a note in the writing state.
    func insertWritingSample() -> UUID {
        let note = NoteItem(id: UUID(), title: "", createdAt: Date(), duration: 95,
                            state: .writing, writtenOn: .onDevice)
        notes.insert(note, at: 0)
        return note.id
    }
    #endif
}

// MARK: - Markdown

/// Generated notes as markdown, in the shape the core's template writes:
/// `# Title`, then `**Section**` (or `## Section`) headers with paragraphs
/// and `- ` items. Saved notes also carry a metadata comment (duration and
/// where they were written), never shown or exported.
enum NoteMarkdown {
    struct Parsed {
        var title = ""
        var sections: [NoteSection] = []
        var duration: TimeInterval = 0
        var writtenOn: NotesDestination?
    }

    private static let metaPrefix = "<!-- recordless "

    static func parse(_ markdown: String) -> Parsed {
        var out = Parsed()
        var current: NoteSection?
        func flush() {
            if var s = current {
                s.text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.title.isEmpty || !s.text.isEmpty || !s.items.isEmpty { out.sections.append(s) }
            }
            current = nil
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(metaPrefix) {
                parseMeta(line, into: &out)
                continue
            }
            if line.hasPrefix("# ") {
                let t = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if out.title.isEmpty, !t.hasPrefix("<") { out.title = stripEmphasis(t) }
                continue
            }
            if let header = header(line) {
                flush()
                current = NoteSection(title: header)
                continue
            }
            if let (text, done) = item(line) {
                if current == nil { current = NoteSection(title: "") }
                let isAction = NoteSection.isActionSection(current!.title)
                current!.items.append(.init(text: text, done: done ?? (isAction ? false : nil)))
                continue
            }
            if line.isEmpty {
                if current != nil, !current!.text.isEmpty, !current!.text.hasSuffix("\n\n") { current!.text += "\n" }
                continue
            }
            if current == nil { current = NoteSection(title: "") }
            if !current!.text.isEmpty, !current!.text.hasSuffix("\n") { current!.text += " " }
            current!.text += line
        }
        flush()
        return out
    }

    static func render(_ note: NoteItem, metadata: Bool = false) -> String {
        var out = "# \(note.displayTitle)\n\n"
        for section in note.sections {
            if !section.title.isEmpty { out += "**\(section.title)**\n\n" }
            let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out += text + "\n\n" }
            if !section.items.isEmpty {
                out += section.items.map { item in
                    switch item.done {
                    case .some(true): "- [x] \(item.text)"
                    case .some(false): "- [ ] \(item.text)"
                    case .none: "- \(item.text)"
                    }
                }.joined(separator: "\n") + "\n\n"
            }
        }
        if metadata {
            var meta = metaPrefix + "duration=\(Int(note.duration))"
            if let on = note.writtenOn { meta += " on=\(on.rawValue)" }
            out += meta + " -->\n"
        }
        return out
    }

    private static func parseMeta(_ line: String, into out: inout Parsed) {
        for pair in line.dropFirst(metaPrefix.count).split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "duration": out.duration = TimeInterval(kv[1]) ?? 0
            case "on": out.writtenOn = NotesDestination(rawValue: kv[1])
            default: break
            }
        }
    }

    /// `**Title**`, `## Title` or `### Title` alone on a line.
    private static func header(_ line: String) -> String? {
        if line.hasPrefix("## ") || line.hasPrefix("### ") {
            return stripEmphasis(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
        }
        if line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") {
            let inner = String(line.dropFirst(2).dropLast(2))
            if !inner.contains("**") { return inner.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":")) }
        }
        return nil
    }

    /// `- text`, `* text`, `1. text`, with an optional `[ ]` / `[x]`.
    private static func item(_ line: String) -> (String, Bool?)? {
        var rest: Substring
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            rest = line.dropFirst(2)
        } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber),
                  !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
            rest = line[line.index(dot, offsetBy: 2)...]
        } else {
            return nil
        }
        var done: Bool?
        if rest.hasPrefix("[ ] ") { done = false; rest = rest.dropFirst(4) }
        else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { done = true; rest = rest.dropFirst(4) }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (text, done)
    }

    private static func stripEmphasis(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }
}

#if DEBUG
/// Sample notes for checking layouts (`-ui-screen`). Debug builds only.
enum MockNotes {
    static func sample(now: Date = Date()) -> [NoteItem] {
        let md = """
        # Product roadmap review

        **Meeting Summary**

        The team reviewed progress on the spring release and agreed to move the search work forward.

        **Decisions and Agreements**

        - Ship search in the spring release.

        **Next Steps**

        - Draft the release plan (product lead)
        """
        let p = NoteMarkdown.parse(md)
        return [NoteItem(id: UUID(), title: p.title, createdAt: now.addingTimeInterval(-3600),
                         duration: 18 * 60, state: .saved, writtenOn: .onDevice, sections: p.sections)]
    }
}
#endif
