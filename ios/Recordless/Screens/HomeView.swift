import SwiftUI

/// SPEC 2, `Home.dc.html`: the Listen tab.
struct HomeView: View {
    @Environment(AppFlow.self) private var flow
    @State private var microphone = "iPhone Microphone"
    @State private var language = "English"
    @State private var lockRefusal: String?
    @State private var startBlocker: AppFlow.StartBlocker?

    var body: some View {
        let now = Date()
        let today = flow.library.notes.filter { Calendar.current.isDateInToday($0.createdAt) }
        let earlier = flow.library.notes.filter { NoteGrouping.isEarlierThisWeek($0.createdAt, now: now) }

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(now)
                startCard
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel("Today")
                        Spacer()
                        Button("All notes") { flow.tab = .notes }
                            .buttonStyle(TextButtonStyle(size: Theme.Size.secondary))
                            .frame(minHeight: 0)
                    }
                    if today.isEmpty {
                        emptyToday
                    } else {
                        ForEach(today) { TodayCard(note: $0) }
                    }
                    if !earlier.isEmpty {
                        SectionLabel("Earlier this week").padding(.top, 8)
                        VStack(spacing: 0) {
                            ForEach(Array(earlier.enumerated()), id: \.element.id) { i, note in
                                EarlierRow(note: note, showsDivider: i < earlier.count - 1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.screenSide)
            .padding(.top, Theme.Spacing.topInset)
            .padding(.bottom, 20)
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Listen")
        .alert("Notebook not locked", isPresented: isPresent($lockRefusal), presenting: lockRefusal) { _ in
            Button("Discard and lock", role: .destructive) { flow.lock(force: true) }
            Button("Keep working", role: .cancel) {}
        } message: { Text($0) }
        .alert(startBlocker == .writing ? "Notes are being written" : "Start a new session?",
               isPresented: isPresent($startBlocker), presenting: startBlocker) { blocker in
            if blocker == .unsavedDraft {
                Button("Start listening", role: .destructive) { flow.startListening() }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { blocker in
            Text(blocker == .writing
                 ? "Wait for the notes to finish before starting a new session."
                 : "Your unsaved draft keeps its notes, but its transcript is cleared, so it can't be rewritten from a template.")
        }
    }

    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    private func header(_ now: Date) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(Theme.font(Theme.Size.control))
                    .foregroundStyle(Theme.mutedForeground)
                Text(Self.greeting(for: now))
                    .font(Theme.font(Theme.Size.largeTitle, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.foreground)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            CircleIconButton(systemImage: "lock", label: "Lock notebook") { lockRefusal = flow.lock() }
        }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Microphone", selection: $microphone) {
                        Text("iPhone Microphone").tag("iPhone Microphone")
                    }
                } label: {
                    Pill(title: microphone, showsChevron: true) {
                        Image(systemName: "mic").foregroundStyle(Theme.mutedForeground)
                    }
                }
                .touchTarget()
                .accessibilityLabel("Microphone: \(microphone)")
                Menu {
                    Picker("Language", selection: $language) {
                        Text("English").tag("English")
                    }
                } label: {
                    Pill(title: language, showsChevron: true) {
                        Image(systemName: "globe").foregroundStyle(Theme.mutedForeground)
                    }
                }
                .touchTarget()
                .accessibilityLabel("Language: \(language)")
            }
            PrimaryButton(title: "Start listening", systemImage: "waveform") {
                if let blocker = flow.startBlocker { startBlocker = blocker } else { flow.startListening() }
            }
            InMemoryLine(rest: "no audio or transcript is saved")
        }
        .padding(18)
        .cardStyle(radius: Theme.Radius.largeCard)
    }

    private var emptyToday: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No notes today.").font(Theme.font(Theme.Size.row, .bold))
                .foregroundStyle(Theme.foreground)
            Text("Your notes will appear here.").font(Theme.font(Theme.Size.secondary))
                .foregroundStyle(Theme.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardStyle()
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct TodayCard: View {
    @Environment(AppFlow.self) private var flow
    let note: NoteItem

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.displayTitle).font(Theme.font(Theme.Size.row, .bold))
                    .foregroundStyle(Theme.foreground)
                Spacer()
                Text(note.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                    .foregroundStyle(Theme.mutedForeground)
            }
            switch note.state {
            case .writing:
                HStack(spacing: 8) {
                    ProgressRing()
                    Text(note.writtenOn == .onDevice ? "Writing notes on this iPhone…" : "Writing notes in the private cloud…")
                }
                .font(Theme.font(Theme.Size.secondary, .semibold))
                .foregroundStyle(Theme.info)
            case .queued:
                StatusTag(text: "Queued", kind: .queued, compact: true)
            case .draft, .saved:
                if !note.firstSummaryLine.isEmpty {
                    Text(note.firstSummaryLine).font(Theme.font(Theme.Size.secondary))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(2)
                }
                if note.state == .draft {
                    StatusTag(text: "Draft", kind: .draft, compact: true)
                } else {
                    StatusTag(text: "Notes ready", kind: .ready, systemImage: "checkmark", compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardStyle()

        if note.state == .writing || note.state == .queued {
            content.accessibilityElement(children: .combine)
        } else {
            Button { flow.open(note.id, from: .listen) } label: { content }
                .buttonStyle(.plain)
        }
    }
}

private struct EarlierRow: View {
    @Environment(AppFlow.self) private var flow
    let note: NoteItem
    let showsDivider: Bool

    var body: some View {
        Button { flow.open(note.id, from: .listen) } label: {
            HStack(spacing: 8) {
                Text(note.displayTitle).font(Theme.font(Theme.Size.row))
                    .foregroundStyle(Theme.foreground)
                Spacer()
                Text(note.createdAt.formatted(.dateTime.weekday(.abbreviated)))
                    .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                    .foregroundStyle(Theme.mutedForeground)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showsDivider { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .buttonStyle(.plain)
        .disabled(note.state == .writing)
    }
}

#Preview {
    let flow = AppFlow(app: AppModel())
    NavigationStack { HomeView() }.environment(flow)
}
