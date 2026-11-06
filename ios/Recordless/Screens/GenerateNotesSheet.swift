import SwiftUI

/// SPEC 4, `Generate.dc.html`. Presented over the Live screen after End
/// session; it can't be swiped away, so the session ends in Generate or
/// Discard.
struct GenerateNotesSheet: View {
    @Environment(AppFlow.self) private var flow
    @State private var destination: NotesDestination = .onDevice
    @State private var scrub = ScrubSetting()
    @State private var confirmDiscard = false

    var body: some View {
        let session = flow.session
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                StatusTag(text: "Session ended", kind: .ended, systemImage: "checkmark")
                Text("Generate notes")
                    .font(Theme.font(Theme.Size.sheetTitle, .bold, relativeTo: .title))
                    .foregroundStyle(Theme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("\(DurationFormat.minutes(session.elapsed())) · \(session.segmentCount.formatted()) \(session.segmentCount == 1 ? "segment" : "segments") held in memory. They clear once you save notes or discard.")
                    .font(Theme.font(Theme.Size.control))
                    .foregroundStyle(Theme.mutedForeground)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Write notes with").padding(.bottom, 0)
                RadioCard(title: "On this iPhone",
                          detail: "A local model with no network access. Nothing leaves your device.",
                          selected: destination == .onDevice) { destination = .onDevice }
                RadioCard(title: "Private cloud",
                          detail: "A secure enclave on NEAR AI. Text is sent only after its attestation verifies.",
                          selected: destination == .privateCloud) { destination = .privateCloud }
                if destination == .privateCloud {
                    AttestationRow(state: flow.library.cloudReadiness)
                }
            }

            ToggleCard(title: "Scrub identifiers",
                       subtitle: "Applied before any text reaches the private cloud",
                       isOn: $scrub.requestedIsOn)

            VStack(spacing: 8) {
                if let blocker {
                    Text(blocker)
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryButton(title: "Generate notes") { flow.generateNotes(on: destination, scrub: scrub.isOn) }
                    .disabled(blocker != nil || flow.library.isWriting
                              || destination == .privateCloud && flow.library.cloudReadiness != .ready)
                Button("Discard session", role: .destructive) { confirmDiscard = true }
                    .buttonStyle(TextButtonStyle(color: Theme.destructive))
                    .frame(maxWidth: .infinity)
            }
        }
        .fittedSheet()
        .interactiveDismissDisabled()
        .scrubConfirmation(scrub: $scrub)
        .confirmationDialog("Discard this session? The transcript is cleared from memory.",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard session", role: .destructive) { flow.discardSession() }
            Button("Keep session", role: .cancel) {}
        }
        .task(id: destination) {
            if destination == .privateCloud { await flow.library.refreshCloud() }
        }
    }

    /// Why Generate is disabled, or nil.
    private var blocker: String? {
        if let b = flow.library.sessionBlocker { return b }
        switch destination {
        case .onDevice: return flow.library.onDeviceBlocker
        case .privateCloud: return nil        // shown by AttestationRow
        }
    }
}

/// Whether the private cloud can take the request. The enclave's
/// attestation is verified by the core on the connection that carries the
/// notes; nothing is sent unless it passes.
struct AttestationRow: View {
    let state: NotesLibrary.CloudReadiness

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .checking:
                ProgressView().controlSize(.mini).tint(Theme.info)
                Text("Checking the private cloud…").foregroundStyle(Theme.info)
            case .ready:
                Image(systemName: "checkmark.seal").foregroundStyle(Theme.success)
                Text("Attestation is verified before anything is sent").foregroundStyle(Theme.success)
            case .unavailable(let reason):
                Image(systemName: "icloud.slash").foregroundStyle(Theme.mutedForeground)
                Text(reason).foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.font(Theme.Size.meta, .semibold, relativeTo: .footnote))
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scrubbing

/// Scrubbing is on by default. Turning it off needs a confirmation that
/// can't be skipped (hard rule); `pendingOff` holds the request until then.
struct ScrubSetting {
    private(set) var isOn = true
    var pendingOff = false

    mutating func request(_ on: Bool) {
        if on { isOn = true } else { pendingOff = true }
    }

    mutating func confirmOff() {
        isOn = false
        pendingOff = false
    }
}

extension Binding where Value == ScrubSetting {
    /// For a `Toggle`: turning on applies at once, turning off asks first.
    var requestedIsOn: Binding<Bool> {
        Binding<Bool>(get: { wrappedValue.isOn }, set: { wrappedValue.request($0) })
    }
}

extension View {
    /// Alert that must be answered before scrubbing turns off.
    func scrubConfirmation(scrub: Binding<ScrubSetting>) -> some View {
        alert("Turn off scrubbing?", isPresented: scrub.pendingOff) {
            Button("Turn off", role: .destructive) { scrub.wrappedValue.confirmOff() }
            Button("Keep scrubbing", role: .cancel) {}
        } message: {
            Text("Names, emails, phone numbers, links and ID numbers will no longer be removed before notes are written. With the private cloud, that text is sent to the secure enclave.")
        }
    }
}
