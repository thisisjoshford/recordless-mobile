import SwiftUI
import UniformTypeIdentifiers

/// SPEC 5, `Note.dc.html`. Drafts are editable and have the review band and
/// bottom bar; saved notes are read-only (the notebook can't update a note).
struct NoteView: View {
    @Environment(AppFlow.self) private var flow
    let noteID: UUID
    @State private var editingTemplate = false
    /// Local edits, written to the library after a pause, on leaving, and
    /// before Save (not on every keystroke).
    @State private var draft: NoteItem?
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmDiscard = false

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
        let unsaved = note.state != .saved

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(binding, editable: isDraft)
                if isDraft { ReviewBand() }
                switch note.state {
                case .writing:
                    WritingBand(onDevice: note.writtenOn != .privateCloud, step: flow.library.writingStep)
                case .failed:
                    FailedBand(message: note.error ?? "Notes couldn't be written.",
                               canRetry: flow.session.hasTranscript && flow.library.sessionBlocker == nil) {
                        flow.retry(noteID, scrub: true)
                    }
                case .draft, .saved:
                    if isDraft, let error = note.error {
                        Text(error)
                            .font(Theme.font(Theme.Size.secondary, .semibold))
                            .foregroundStyle(Theme.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    sections(binding, editable: isDraft)
                }
                if let saveError {
                    Text(saveError)
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .foregroundStyle(Theme.destructive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .disabled(note.state == .writing || note.state == .failed)
                Menu {
                    Button("Copy notes", systemImage: "doc.on.doc") {
                        // This device only (no Universal Clipboard), and
                        // gone after a few minutes.
                        UIPasteboard.general.setItems(
                            [[UTType.utf8PlainText.identifier: NoteExport.markdown(draft ?? note)]],
                            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(180)])
                    }
                    .disabled(note.state == .writing || note.state == .failed)
                    if unsaved && flow.canRewrite(noteID) {
                        Button("Discard notes", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More actions")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if unsaved {
                HStack(spacing: 10) {
                    if flow.canRewrite(noteID) {
                        SecondaryButton(title: "Edit template", systemImage: "slider.horizontal.3",
                                        height: Theme.Spacing.barButton) { flush(); editingTemplate = true }
                    } else {
                        SecondaryButton(title: "Discard", systemImage: "trash",
                                        height: Theme.Spacing.barButton) { confirmDiscard = true }
                            .disabled(saving || flow.library.isSaving(noteID))
                    }
                    if isDraft {
                        PrimaryButton(title: saving ? "Saving…" : "Save notes", systemImage: "checkmark",
                                      height: Theme.Spacing.barButton) {
                            Task { await save(note) }
                        }
                        .disabled(saving)
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
        // The library moved the note on (notes written): its version wins
        // over local edits.
        .onChange(of: note.state) { draft = nil }
        .onDisappear { flush() }
        .sheet(isPresented: $editingTemplate) {
            EditTemplateSheet(noteID: noteID, destination: note.writtenOn)
        }
        .confirmationDialog("Discard these notes? The transcript is cleared from memory too.",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard notes", role: .destructive) {
                draft = nil
                flow.discardSession()
            }
            Button("Keep notes", role: .cancel) {}
        }
    }

    private func save(_ note: NoteItem) async {
        saving = true
        saveError = nil
        let edited = draft ?? note
        draft = nil
        saveError = await flow.save(edited)
        saving = false
    }

    private func flush() {
        guard let draft else { return }
        if let current = flow.library.note(noteID), current.state == .draft, draft != current {
            flow.library.update(draft)
        }
        self.draft = nil
    }

    private func header(_ note: Binding<NoteItem>, editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if editable {
                    TextField("Title", text: note.title, axis: .vertical)
                        .accessibilityLabel("Title")
                } else if note.wrappedValue.state == .writing && note.wrappedValue.title.isEmpty {
                    Text("New session")
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
                switch note.wrappedValue.writtenOn {
                case .onDevice:
                    StatusTag(text: "Written on this iPhone", kind: .neutral, systemImage: "iphone")
                case .privateCloud:
                    StatusTag(text: "Written in the private cloud", kind: .neutral, systemImage: "cloud")
                case nil:
                    EmptyView()
                }
                if editable { StatusTag(text: "Draft", kind: .draft, systemImage: "pencil") }
            }
        }
    }

    @ViewBuilder
    private func sections(_ note: Binding<NoteItem>, editable: Bool) -> some View {
        let body = Theme.font(Theme.Size.body)
        if note.wrappedValue.sections.isEmpty {
            Text("The notes came back empty.")
                .font(body)
                .foregroundStyle(Theme.mutedForeground)
        }
        ForEach(note.sections) { $section in
            VStack(alignment: .leading, spacing: 8) {
                if !section.title.isEmpty { SectionLabel(section.title) }
                if editable || !section.text.isEmpty {
                    if editable {
                        if !section.text.isEmpty || section.items.isEmpty {
                            TextField(section.title.isEmpty ? "Notes" : section.title,
                                      text: $section.text, axis: .vertical)
                                .font(body)
                                .lineSpacing(Theme.Size.body * 0.3)
                                .foregroundStyle(Theme.foreground)
                        }
                    } else {
                        Text(inlineMarkdown(section.text))
                            .font(body)
                            .lineSpacing(Theme.Size.body * 0.3)
                            .foregroundStyle(Theme.foreground)
                            .textSelection(.enabled)
                    }
                }
                if !section.items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach($section.items) { $item in
                            ItemRow(item: $item, editable: editable)
                        }
                    }
                }
            }
        }
    }
}

/// Progress while notes are written. The step comes from the core
/// ("Summary chunk 2 of 3", ...) when it reports one.
private struct WritingBand: View {
    let onDevice: Bool
    let step: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressRing()
                Text(onDevice ? "Writing notes on this iPhone…" : "Writing notes in the private cloud…")
                    .font(Theme.font(Theme.Size.row, .bold))
                    .foregroundStyle(Theme.info)
            }
            if let step, !step.isEmpty {
                Text(step)
                    .font(Theme.font(Theme.Size.secondary, .semibold))
                    .foregroundStyle(Theme.foreground)
            }
            Text(onDevice
                 ? "This can take a few minutes for a long session. Keep Recordless open; the screen stays on."
                 : "The transcript is sent only after the secure enclave's attestation verifies.")
                .font(Theme.font(Theme.Size.secondary))
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.infoSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A failed notes run. The core keeps the transcript, so it can be retried.
private struct FailedBand: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Notes weren't written", systemImage: "exclamationmark.circle")
                .font(Theme.font(Theme.Size.row, .bold))
                .foregroundStyle(Theme.destructive)
            Text(message)
                .font(Theme.font(Theme.Size.secondary))
                .foregroundStyle(Theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                SecondaryButton(title: "Try again", systemImage: "arrow.clockwise", action: retry)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(shadow: false)
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

private struct ItemRow: View {
    @Binding var item: NoteSection.Item
    let editable: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let done = item.done {
                Button { item.done = !done } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundStyle(done ? Theme.primary : Theme.mutedForeground)
                        .frame(width: Theme.Spacing.minTouch, height: Theme.Spacing.minTouch, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(!editable)
                .accessibilityLabel(item.text)
                .accessibilityValue(done ? "Done" : "Not done")
                .accessibilityHint(editable ? "Double-tap to toggle." : "")
            } else {
                Text("•").accessibilityHidden(true)
            }
            Group {
                if editable {
                    TextField("Item", text: $item.text, axis: .vertical)
                } else {
                    Text(inlineMarkdown(item.text))
                        .strikethrough(item.done == true, color: Theme.mutedForeground)
                        .textSelection(.enabled)
                }
            }
            .font(Theme.font(Theme.Size.body))
            .foregroundStyle(Theme.foreground)
        }
        .frame(minHeight: item.done == nil ? nil : Theme.Spacing.minTouch)
    }
}

private func inlineMarkdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

/// Plain-text export for Share and Copy. Generated notes only.
enum NoteExport {
    static func markdown(_ note: NoteItem) -> String { NoteMarkdown.render(note) }
}
