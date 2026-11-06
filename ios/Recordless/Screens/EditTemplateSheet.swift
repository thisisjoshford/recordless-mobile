import SwiftUI

/// SPEC 6, `Template.dc.html`. Only offered while the draft's transcript is
/// still in memory. The template goes to the notes model as style
/// instructions; it can't override the privacy rules.
struct EditTemplateSheet: View {
    @Environment(AppFlow.self) private var flow
    @Environment(\.dismiss) private var dismiss
    let noteID: UUID

    @State private var template = Self.defaultTemplate
    @State private var destination: NotesDestination
    @State private var scrub = ScrubSetting()

    init(noteID: UUID, destination: NotesDestination?) {
        self.noteID = noteID
        _destination = State(initialValue: destination ?? .onDevice)
    }

    static let defaultTemplate =
        "Summarize the discussion, the decisions and agreements, open questions, and next steps."

    private static let quickAdds: [(title: String, sentence: String)] = [
        ("More detail", "Be more detailed."),
        ("Bullets only", "Use bullet points only."),
        ("Action items first", "Put next steps and owners at the top."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Text("Edit template")
                    .font(Theme.font(Theme.Size.body, .bold))
                    .foregroundStyle(Theme.foreground)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(TextButtonStyle(size: Theme.Size.body))
                        .fontWeight(.regular)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Template")
                TextField("Template", text: $template, axis: .vertical)
                    .onChange(of: template) { flow.noteActivity() }
                    .autocorrectionDisabled()
                    .lineLimit(4...8)
                    .font(Theme.font(Theme.Size.body))
                    .foregroundStyle(Theme.foreground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .cardStyle(radius: Theme.Radius.input, shadow: false)
                    .accessibilityLabel("Template")
                FlowRow(spacing: 8) {
                    ForEach(Self.quickAdds, id: \.title) { item in
                        let added = template.contains(item.sentence)
                        Button { append(item.sentence) } label: {
                            Pill(title: (added ? "✓ " : "+ ") + item.title, selected: added,
                                 fill: Theme.card, textColor: Theme.primary, weight: .semibold)
                        }
                        .buttonStyle(.plain)
                        .touchTarget()
                        .disabled(added)
                        .accessibilityLabel(added ? "\(item.title), added" : "Add \(item.title)")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Rewrite on")
                Picker("Rewrite on", selection: $destination) {
                    Label("This iPhone", systemImage: "iphone").tag(NotesDestination.onDevice)
                    Label("Private cloud", systemImage: "cloud").tag(NotesDestination.privateCloud)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
            }

            ToggleCard(title: "Scrub personal info",
                       subtitle: "Names, emails, phone numbers, links, IDs",
                       isOn: $scrub.requestedIsOn)

            VStack(spacing: 8) {
                PrimaryButton(title: "Rewrite notes") {
                    flow.rewrite(noteID, template: template, on: destination, scrub: scrub.isOn)
                    dismiss()
                }
                .disabled(template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || blocker != nil)
                if let blocker {
                    Text(blocker)
                        .font(Theme.font(Theme.Size.meta, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Theme.mutedForeground)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                Text("The draft is rewritten from this template. The transcript stays in memory until you save.")
                    .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                    .foregroundStyle(Theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .fittedSheet()
        .scrubConfirmation(scrub: $scrub)
        .task(id: destination) {
            if destination == .privateCloud { await flow.library.refreshCloud() }
        }
    }

    /// Why Rewrite is disabled for the chosen destination, or nil.
    private var blocker: String? {
        switch destination {
        case .onDevice: return flow.library.onDeviceBlocker
        case .privateCloud:
            switch flow.library.cloudReadiness {
            case .ready: return nil
            case .checking: return "Checking the private cloud…"
            case .unavailable(let reason): return reason
            }
        }
    }

    private func append(_ sentence: String) {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        template = trimmed.isEmpty ? sentence : trimmed + " " + sentence
    }
}

/// Wrapping row for chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + extra > width {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
