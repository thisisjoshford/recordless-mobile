import Foundation
import Observation

enum NotesDestination: String, CaseIterable, Identifiable {
    case onDevice, privateCloud
    var id: String { rawValue }
}

/// A note as the UI sees it. Generated notes only; never transcript text.
struct NoteItem: Identifiable, Equatable {
    enum State: Equatable { case writing, queued, draft, saved }

    struct ActionItem: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var done = false
    }

    let id: UUID
    var title: String
    let createdAt: Date
    let duration: TimeInterval
    var state: State
    var writtenOn: NotesDestination
    var summary: String = ""
    var decisions: [String] = []
    var actions: [ActionItem] = []

    var displayTitle: String { title.isEmpty ? "Untitled session" : title }
    var firstSummaryLine: String {
        summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// Generated notes the Notes search may match. Never a transcript.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let haystack = ([title, summary] + decisions + actions.map(\.text)).joined(separator: "\n")
        return haystack.localizedStandardContains(q)
    }
}

/// The notebook, on mock data until Milestone 5 wires the encrypted vault.
@Observable
@MainActor
final class NotesLibrary {
    private(set) var notes: [NoteItem]
    /// Called when a notes run ends (finished or cancelled).
    @ObservationIgnored var onWriteFinished: (() -> Void)?
    @ObservationIgnored private var writers: [UUID: Task<Void, Never>] = [:]

    var isWriting: Bool { notes.contains { $0.state == .writing } }
    static let defaultTemplate =
        "Summarize the discussion, the decisions and agreements, open questions, and next steps."

    init(notes: [NoteItem] = MockNotes.sample()) {
        self.notes = notes
    }

    func note(_ id: UUID) -> NoteItem? { notes.first { $0.id == id } }

    func update(_ note: NoteItem) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i] = note
    }

    /// Starts writing notes for a finished session. Returns the new note's id.
    /// `scrub` is the person's confirmed scrubbing choice; there is no
    /// default so it can't be dropped on the way to the generator.
    func startDraft(duration: TimeInterval, on destination: NotesDestination, scrub: Bool) -> UUID {
        let note = NoteItem(id: UUID(), title: "", createdAt: Date(), duration: duration,
                            state: .writing, writtenOn: destination)
        notes.insert(note, at: 0)
        writers[note.id] = Task { await mockWrite(note.id, scrub: scrub) }
        return note.id
    }

    /// Rewrites a draft from a template (draft state only, while the
    /// transcript is still in memory).
    func rewrite(_ id: UUID, template: String, on destination: NotesDestination, scrub: Bool) {
        guard var note = note(id), note.state == .draft else { return }
        note.state = .writing
        note.writtenOn = destination
        update(note)
        writers[id] = Task { await mockWrite(id, scrub: scrub) }
    }

    /// Stops every notes run (discard, lock). A first run's empty note is
    /// removed; a rewrite falls back to its previous draft.
    func cancelWriting() {
        guard !writers.isEmpty else { return }
        writers.values.forEach { $0.cancel() }
        writers = [:]
        notes.removeAll { $0.state == .writing && $0.summary.isEmpty }
        for i in notes.indices where notes[i].state == .writing { notes[i].state = .draft }
        onWriteFinished?()
    }

    func save(_ id: UUID) {
        guard var note = note(id), note.state == .draft else { return }
        note.state = .saved
        update(note)
    }

    private func mockWrite(_ id: UUID, scrub: Bool) async {
        defer {
            if !Task.isCancelled {
                writers[id] = nil
                onWriteFinished?()
            }
        }
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled, var note = note(id), note.state == .writing else { return }
        let content = MockNotes.generated()
        if note.title.isEmpty { note.title = content.title }
        note.summary = content.summary
        note.decisions = content.decisions
        note.actions = content.actions.map { NoteItem.ActionItem(text: $0) }
        note.state = .draft
        update(note)
    }
}

/// Mock content for building the UI. Replaced by the vault and the notes
/// model in Milestones 5 and 7.
enum MockNotes {
    static func sample(now: Date = Date()) -> [NoteItem] {
        let cal = Calendar.current
        func at(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        let g = generated()
        return [
            NoteItem(id: UUID(), title: "Quarterly planning", createdAt: at(daysAgo: 0, hour: 9, minute: 0),
                     duration: 18 * 60, state: .saved, writtenOn: .onDevice,
                     summary: g.summary, decisions: g.decisions,
                     actions: g.actions.map { .init(text: $0) }),
            NoteItem(id: UUID(), title: "Hiring sync", createdAt: at(daysAgo: 2, hour: 16, minute: 0),
                     duration: 45 * 60, state: .saved, writtenOn: .privateCloud,
                     summary: "Reviewed the pipeline for the two open roles and agreed on a shorter interview loop.",
                     decisions: ["Drop the take-home exercise."], actions: [.init(text: "Update the job posts — Hiring lead")]),
            NoteItem(id: UUID(), title: "Design critique", createdAt: at(daysAgo: 2, hour: 10, minute: 30),
                     duration: 25 * 60, state: .saved, writtenOn: .onDevice,
                     summary: "Walked through the onboarding flow and collected feedback on the empty states."),
            NoteItem(id: UUID(), title: "Weekly one-on-one", createdAt: at(daysAgo: 3, hour: 18, minute: 15),
                     duration: 12 * 60, state: .saved, writtenOn: .onDevice,
                     summary: "Talked through priorities for next week and a conference talk proposal."),
            NoteItem(id: UUID(), title: "Vendor review", createdAt: at(daysAgo: 24, hour: 14, minute: 0),
                     duration: 38 * 60, state: .saved, writtenOn: .onDevice,
                     summary: "Compared three hosting vendors on cost, support and data residency."),
        ]
    }

    static func generated() -> (title: String, summary: String, decisions: [String], actions: [String]) {
        ("Product roadmap review",
         "The team reviewed progress on the spring release, agreed to move the search work forward, and flagged open questions about pricing for the team plan.",
         ["Ship search in the spring release.", "Hold pricing changes until after customer interviews."],
         ["Draft the release plan — Product lead", "Schedule five customer interviews — Research"])
    }
}
