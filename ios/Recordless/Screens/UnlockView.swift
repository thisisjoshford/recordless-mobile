import LocalAuthentication
import SwiftUI

/// SPEC 1, `Main.dc.html`. The notebook has no passphrase (Face ID, with the
/// device passcode as the system fallback), so the design's "Use passphrase
/// instead" link is left out.
struct UnlockView: View {
    @Environment(AppFlow.self) private var flow
    @State private var message: String?
    @State private var busy = false

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
                Label("Notebook locked", systemImage: "lock")
                    .font(Theme.font(Theme.Size.secondary, .semibold))
                    .foregroundStyle(Theme.mutedForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.secondary, in: Capsule())

                PrimaryButton(title: "Unlock with Face ID", systemImage: "faceid") {
                    Task { await unlock() }
                }
                .disabled(busy)

                if let notice = flow.lockNotice, message == nil {
                    Text(notice)
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .foregroundStyle(Theme.mutedForeground)
                        .multilineTextAlignment(.center)
                }

                if let message {
                    Text(message)
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.center)
                }

                Text("Your notes are encrypted on this device. Recordless never stores audio or transcripts.")
                    .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                    .foregroundStyle(Theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 300)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }

    /// Face ID, with the device passcode as the system fallback. Milestone 5
    /// replaces this with VaultLock, which unwraps the notebook key in the
    /// Secure Enclave under the same check.
    private func unlock() async {
        busy = true
        defer { busy = false }
        message = nil
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            #if DEBUG && targetEnvironment(simulator)
            flow.didAuthenticate()      // simulator without Face ID enrolled
            #else
            message = "Set a passcode for this iPhone to use Recordless."
            #endif
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your notebook")
            flow.didAuthenticate()
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
            // Cancelled: no message.
        } catch {
            message = "Didn't recognise that. Try again, or use your iPhone passcode."
        }
    }
}

#Preview {
    UnlockView().environment(AppFlow(app: AppModel()))
}
