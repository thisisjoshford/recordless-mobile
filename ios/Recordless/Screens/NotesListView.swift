import SwiftUI

/// SPEC 7, `Notes.dc.html`. Search covers generated notes only.
struct NotesListView: View {
    @Environment(AppFlow.self) private var flow
    @State private var query = ""

    var body: some View {
        let matches = flow.library.notes
            .filter { $0.matches(query) }
            .sorted { $0.createdAt > $1.createdAt }
        let groups = NoteGrouping.groups(matches)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Notes")
                        .font(Theme.font(Theme.Size.largeTitle, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(Theme.foreground)
                        .accessibilityAddTraits(.isHeader)
                    SearchField(text: $query)
                    Text("Searches your notes only — transcripts are never kept.")
                        .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                        .foregroundStyle(Theme.mutedForeground)
                }
                if let error = flow.library.loadError {
                    Text(error)
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .foregroundStyle(Theme.destructive)
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "No notes yet." : "No matching notes.")
                        .font(Theme.font(Theme.Size.row))
                        .foregroundStyle(Theme.mutedForeground)
                        .padding(.top, 8)
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(group.title).padding(.top, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(group.notes.enumerated()), id: \.element.id) { i, note in
                                NoteRow(note: note)
                                    .overlay(alignment: .top) {
                                        if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                                    }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .cardStyle(shadow: false)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.screenSide)
            .padding(.top, Theme.Spacing.topInset)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Notes")
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.mutedForeground)
                .accessibilityHidden(true)
            TextField("Search notes", text: $text)
                .font(Theme.font(Theme.Size.body))
                .foregroundStyle(Theme.foreground)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mutedForeground)
                        .frame(width: Theme.Spacing.minTouch, height: Theme.Spacing.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -12)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Theme.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous))
    }
}

private struct NoteRow: View {
    @Environment(AppFlow.self) private var flow
    let note: NoteItem

    var body: some View {
        let writing = note.state == .writing
        let row = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayTitle)
                    .font(Theme.font(Theme.Size.row, .bold))
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(1)
                if writing {
                    Text("Writing notes…")
                        .font(Theme.font(Theme.Size.meta, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Theme.info)
                } else {
                    Text(NoteGrouping.rowMeta(note))
                        .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                        .foregroundStyle(Theme.mutedForeground)
                }
            }
            Spacer(minLength: 0)
            switch note.state {
            case .writing: ProgressRing(size: 18)
            case .failed: StatusTag(text: "Not written", kind: .draft, compact: true)
            case .draft: StatusTag(text: "Draft", kind: .draft, compact: true)
            case .saved: EmptyView()
            }
            if !writing {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.Spacing.rowHeight)
        .background(Theme.card)
        .contentShape(Rectangle())

        if writing {
            row.accessibilityElement(children: .combine)
        } else {
            Button { flow.open(note.id, from: .notes) } label: { row }
                .buttonStyle(.plain)
        }
    }
}

/// Date grouping and meta lines shared by Home and Notes.
enum NoteGrouping {
    struct Group { let title: String; let notes: [NoteItem] }

    /// Earlier in the current calendar week (the locale's first weekday),
    /// not today.
    static func isEarlierThisWeek(_ date: Date, now: Date = Date()) -> Bool {
        let cal = Calendar.current
        return !cal.isDateInToday(date) && date <= now
            && cal.isDate(date, equalTo: now, toGranularity: .weekOfYear)
    }

    /// "Today", "Earlier this week", then by month ("October 2026").
    static func groups(_ notes: [NoteItem], now: Date = Date()) -> [Group] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [NoteItem]] = [:]
        for note in notes {
            let key: String
            if cal.isDateInToday(note.createdAt) {
                key = "Today"
            } else if isEarlierThisWeek(note.createdAt, now: now) {
                key = "Earlier this week"
            } else {
                key = note.createdAt.formatted(.dateTime.month(.wide).year())
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(note)
        }
        return order.map { Group(title: $0, notes: buckets[$0] ?? []) }
    }

    /// "2:30 PM · 32 min" today, "Mon · 4:00 PM · 45 min" this week,
    /// "Oct 10 · 2:00 PM · 38 min" older.
    static func rowMeta(_ note: NoteItem) -> String {
        let time = note.createdAt.formatted(date: .omitted, time: .shortened)
        let dur = note.duration > 0 ? " · \(DurationFormat.minutes(note.duration))" : ""
        if Calendar.current.isDateInToday(note.createdAt) { return "\(time)\(dur)" }
        let day = isEarlierThisWeek(note.createdAt)
            ? note.createdAt.formatted(.dateTime.weekday(.abbreviated))
            : note.createdAt.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) · \(time)\(dur)"
    }

    /// "Today · 2:30 PM · 32 min".
    static func meta(_ note: NoteItem) -> String {
        Calendar.current.isDateInToday(note.createdAt) ? "Today · \(rowMeta(note))" : rowMeta(note)
    }
}
