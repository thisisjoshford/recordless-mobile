import SwiftUI
import UniformTypeIdentifiers

/// SPEC 5, `Note.dc.html`. Drafts are editable and have the review band and
/// bottom bar; saved notes are read-only for now.
struct NoteView: View {
    @Environment(AppFlow.self) private var flow
    let noteID: UUID
    @State private var editingTemplate = false
    /// Local edits, written to the notebook after a pause, on leaving, and
    /// before Save or Edit template (not on every keystroke).
    @State private var draft: NoteItem?

    var body: some View {
        if let note = flow.library.note(noteID) {
            content(note)
        } else {
            ContentUnavailableView("Note not found", systemImage: "doc.text")
        }
    }

    private func content(_ note: NoteItem) -> some View {
        let binding = Binding<NoteItem>(
            get: { draft ?? note },
            set: { draft = $0 })
        let isDraft = note.state == .draft
        let canRewrite = flow.canRewrite(noteID)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(binding, editable: isDraft)
                if isDraft { ReviewBand() }
                switch note.state {
                case .writing, .queued:
                    HStack(spacing: 8) {
                        ProgressRing()
                        Text(note.state == .queued ? "Queued"
                             : note.writtenOn == .onDevice ? "Writing notes on this iPhone…" : "Writing notes in the private cloud…")
                    }
                    .font(Theme.font(Theme.Size.secondary, .semibold))
                    .foregroundStyle(Theme.info)
                case .draft, .saved:
                    sections(binding, editable: isDraft)
                }
            }
            .padding(.horizontal, Theme.Spacing.screenSide)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: NoteExport.markdown(draft ?? note)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
                .disabled(note.state == .writing || note.state == .queued)
                Menu {
                    Button("Copy notes", systemImage: "doc.on.doc") {
                        // This device only (no Universal Clipboard), and
                        // gone after a few minutes.
                        UIPasteboard.general.setItems(
                            [[UTType.utf8PlainText.identifier: NoteExport.markdown(draft ?? note)]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(180)])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More actions")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isDraft {
                HStack(spacing: 10) {
                    SecondaryButton(title: "Edit template", systemImage: "slider.horizontal.3",
                                    height: Theme.Spacing.barButton) { flush(); editingTemplate = true }
                        .disabled(!canRewrite)
                    PrimaryButton(title: "Save notes", systemImage: "checkmark",
                                  height: Theme.Spacing.barButton) {
                        flow.save(draft ?? note)
                        draft = nil
                    }
                }
                .padding(.horizontal, Theme.Spacing.screenSide)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(Theme.card.opacity(0.94).ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .task(id: draft) {
            guard draft != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { flush() }
        }
        // The library moved the note on (notes written, rewrite started):
        // its version wins over local edits.
        .onChange(of: note.state) { draft = nil }
        .onDisappear { flush() }
        #if DEBUG
        .task(id: note.state) {
            if flow.debugTemplate, note.state == .draft { flow.debugTemplate = false; editingTemplate = true }
        }
        #endif
        .sheet(isPresented: $editingTemplate) {
            EditTemplateSheet(noteID: noteID, destination: note.writtenOn)
        }
    }

    private func flush() {
        guard let draft else { return }
        if draft != flow.library.note(noteID) { flow.library.update(draft) }
        self.draft = nil
    }

    private func header(_ note: Binding<NoteItem>, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if editable {
                    TextField("Title", text: note.title, axis: .vertical)
                        .accessibilityLabel("Title")
                } else {
                    Text(note.wrappedValue.displayTitle)
                }
            }
            .font(Theme.font(Theme.Size.noteTitle, .bold, relativeTo: .title))
            .foregroundStyle(Theme.foreground)
            .accessibilityAddTraits(.isHeader)

            Text(NoteGrouping.meta(note.wrappedValue))
                .font(Theme.font(Theme.Size.control))
                .foregroundStyle(Theme.mutedForeground)
            HStack(spacing: 6) {
                if note.wrappedValue.writtenOn == .onDevice {
                    StatusTag(text: "Written on this iPhone", kind: .neutral, systemImage: "iphone")
                } else {
                    StatusTag(text: "Written in the private cloud", kind: .neutral, systemImage: "cloud")
                }
                if editable { StatusTag(text: "Draft", kind: .draft, systemImage: "pencil") }
            }
        }
    }

    @ViewBuilder
    private func sections(_ note: Binding<NoteItem>, editable: Bool) -> some View {
        let body = Theme.font(Theme.Size.body)
        if editable || !note.wrappedValue.summary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Summary")
                Group {
                    if editable {
                        TextField("Summary", text: note.summary, axis: .vertical)
                    } else {
                        Text(note.wrappedValue.summary)
                    }
                }
                .font(body)
                .lineSpacing(Theme.Size.body * 0.3)
                .foregroundStyle(Theme.foreground)
            }
        }
        if !note.wrappedValue.decisions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Decisions")
                ForEach(note.decisions.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•").accessibilityHidden(true)
                        if editable {
                            TextField("Decision", text: note.decisions[i], axis: .vertical)
                        } else {
                            Text(note.wrappedValue.decisions[i])
                        }
                    }
                    .font(body)
                    .foregroundStyle(Theme.foreground)
                }
            }
        }
        if !note.wrappedValue.actions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Action items").padding(.bottom, 4)
                ForEach(note.actions) { $item in
                    ActionRow(item: $item, editable: editable)
                }
            }
        }
    }
}

private struct ReviewBand: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primaryForeground)
                .frame(width: 30, height: 30)
                .background(Theme.primary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Review your draft")
                    .font(Theme.font(Theme.Size.row, .bold))
                    .foregroundStyle(Theme.reviewTitle)
                let save = Text("Save notes").font(Theme.font(Theme.Size.secondary, .bold))
                Text("Edit anything, or rewrite it from a template. \(save) keeps only your notes and clears the transcript.")
                    .font(Theme.font(Theme.Size.secondary))
                    .foregroundStyle(Theme.reviewBody)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.primarySoft, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.primaryBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct ActionRow: View {
    @Binding var item: NoteItem.ActionItem
    let editable: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { item.done.toggle() } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(item.done ? Theme.primary : Theme.mutedForeground)
                    .frame(width: Theme.Spacing.minTouch, height: Theme.Spacing.minTouch, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Mark not done" : "Mark done")
            Group {
                if editable {
                    TextField("Action item", text: $item.text, axis: .vertical)
                } else {
                    Text(item.text).strikethrough(item.done, color: Theme.mutedForeground)
                }
            }
            .font(Theme.font(Theme.Size.body))
            .foregroundStyle(Theme.foreground)
        }
        .frame(minHeight: Theme.Spacing.minTouch)
    }
}

/// Plain-text export for Share and Copy. Generated notes only.
enum NoteExport {
    static func markdown(_ note: NoteItem) -> String {
        var out = "# \(note.displayTitle)\n\n"
        if !note.summary.isEmpty { out += "## Summary\n\n\(note.summary)\n\n" }
        if !note.decisions.isEmpty {
            out += "## Decisions\n\n" + note.decisions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !note.actions.isEmpty {
            out += "## Action items\n\n" + note.actions.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n") + "\n"
        }
        return out
    }
}
