import SwiftUI

/// SPEC 1, `Main.dc.html`. The notebook has no passphrase (Face ID, with the
/// device passcode as the system fallback), so the design's "Use passphrase
/// instead" link is left out.
struct UnlockView: View {
    @Environment(AppFlow.self) private var flow
    @State private var confirmStartOver = false
    private var vault: VaultLock { flow.app.vault }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                LogoView(size: 104)
                Text("Recordless")
                    .font(Theme.wordmark(44))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("Meeting notes without the recording.")
                    .font(Theme.font(Theme.Size.body))
                    .foregroundStyle(Theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                actions

                if let notice = flow.lockNotice, vault.error == nil {
                    Text(notice)
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .foregroundStyle(Theme.mutedForeground)
                        .multilineTextAlignment(.center)
                }

                if let message = vault.error {
                    Text(message)
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.center)
                }

                Text("Your notes are encrypted on this device.\nRecordless never stores audio or transcripts.")
                    .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                    .foregroundStyle(Theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }

    @ViewBuilder private var actions: some View {
        switch vault.state {
        case .noVault:
            #if DEBUG && targetEnvironment(simulator)
            PrimaryButton(title: "Continue without a notebook", systemImage: "iphone") {
                flow.unlockWithoutVault()
            }
            Text("Simulator only: there's no Secure Enclave, so notes stay in memory until you lock.")
                .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                .foregroundStyle(Theme.mutedForeground)
                .multilineTextAlignment(.center)
            #else
            PrimaryButton(title: "Create notebook", systemImage: "lock.shield") {
                Task { await flow.unlock() }
            }
            .disabled(vault.busy || vault.createBlocker != nil)
            Text(vault.createBlocker ?? "Notes are encrypted with a key that never leaves this iPhone. Only Face ID or your passcode can open it.")
                .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                .foregroundStyle(Theme.mutedForeground)
                .multilineTextAlignment(.center)
            #endif
        case .locked, .unlocked:
            PrimaryButton(title: "Unlock with Face ID", systemImage: "faceid") {
                Task { await flow.unlock() }
            }
            .disabled(vault.busy)
        case .keyLost:
            Text("This notebook's key is no longer on this iPhone (for example, the passcode was turned off), so it can't be opened.")
                .font(Theme.font(Theme.Size.secondary))
                .foregroundStyle(Theme.foreground)
                .multilineTextAlignment(.center)
            SecondaryButton(title: "Start a new notebook", systemImage: "plus") { confirmStartOver = true }
                .confirmationDialog("Start a new notebook?", isPresented: $confirmStartOver, titleVisibility: .visible) {
                    Button("Set old notebook aside", role: .destructive) { vault.setAsideAndStartOver() }
                } message: {
                    Text("The old notebook is moved aside and kept, not deleted. Its notes stay unreadable.")
                }
        }
    }
}

#Preview {
    UnlockView().environment(AppFlow(app: AppModel()))
}
