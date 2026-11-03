import Foundation
import Observation
import UIKit

/// Private cloud notes: the core scrubs the transcript and sends it only to a
/// NEAR AI model whose TEE attestation passed on the same TLS connection. The
/// transcript never reaches Swift, and neither does the NEAR AI key (it lives
/// in the vault). Swift sees the notes, counts, timings and what was verified.
@Observable
@MainActor
final class NotesGenerator {
    /// Scrub categories. Every one starts on for each new session.
    var scrubEmails = true
    var scrubPhones = true
    var scrubUrls = true
    var scrubNumbers = true
    var scrubNames = true

    /// Only the model id is remembered, never a key.
    var selectedModelID: String? {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: Self.modelKey) }
    }
    private static let modelKey = "generate.cloudModel"

    private(set) var models: [CloudModel] = []
    private(set) var modelsError: String?
    private(set) var loadingModels = false

    private(set) var credit: CreditStatus?
    private(set) var creditError: String?
    private(set) var redeeming = false

    private(set) var running = false
    private(set) var status: NotesStatus?
    private(set) var result: NotesResult?
    /// The latest report, kept after a failed verification.
    private(set) var verification: VerificationReport?
    private(set) var wallMs: UInt64?
    var error: String?

    @ObservationIgnored private var scrubSession: ObjectIdentifier?
    /// Keeps the request running for a while after the user switches apps.
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// iOS ran out of background time and the request was cancelled.
    @ObservationIgnored private var interruptedInBackground = false

    static let interruptedMessage =
        "Notes were interrupted because iOS stopped the app in the background. "
        + "The transcript is kept: tap Write notes to retry."

    init() {
        selectedModelID = UserDefaults.standard.string(forKey: Self.modelKey)
    }

    var scrub: ScrubOptions {
        ScrubOptions(emails: scrubEmails, phones: scrubPhones, urls: scrubUrls,
                     numbers: scrubNumbers, names: scrubNames)
    }

    var scrubsEverything: Bool {
        scrubEmails && scrubPhones && scrubUrls && scrubNumbers && scrubNames
    }

    /// The model the next request will use: the saved one if NEAR AI still
    /// lists it, else the recommended one. `nil` lets the core pick.
    var effectiveModel: CloudModel? {
        models.first { $0.id == selectedModelID } ?? models.first { $0.recommended }
    }

    /// A new session starts with everything scrubbed again.
    func prepare(for session: Session) {
        let id = ObjectIdentifier(session)
        guard scrubSession != id else { return }
        scrubSession = id
        scrubEmails = true; scrubPhones = true; scrubUrls = true; scrubNumbers = true; scrubNames = true
        clear()
    }

    // MARK: Private cloud account

    func refresh(vault: Vault) async {
        await refreshCredit(vault: vault)
        await loadModels(vault: vault)
    }

    func refreshCredit(vault: Vault) async {
        do {
            credit = try await offMain { try vault.privateCloudStatus() }
            creditError = nil
        } catch {
            creditError = describe(error)
        }
    }

    func loadModels(vault: Vault) async {
        guard !loadingModels else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            models = try await offMain { try vault.listPrivateCloudModels() }
            modelsError = nil
        } catch {
            modelsError = describe(error)
        }
    }

    /// Redeem an activation code (or an own `sk-` key). The key is checked
    /// with NEAR AI and saved in the vault by the core; it never comes back.
    func redeem(code: String, vault: Vault) async -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !redeeming else { return false }
        redeeming = true
        defer { redeeming = false }
        do {
            credit = try await offMain { try vault.redeemActivation(code: code) }
            creditError = nil
            return true
        } catch {
            creditError = describe(error)
            return false
        }
    }

    // MARK: Generate

    func generate(session: Session, vault: Vault) async {
        guard !running else { return }
        running = true
        error = nil
        result = nil
        status = nil
        defer { running = false }

        let scrub = self.scrub
        let modelID = effectiveModel?.id ?? selectedModelID

        // Poll the core's step labels while the request runs.
        let poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let s = await Task.detached { session.notesStatus() }.value
                self?.status = s
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        beginBackgroundTask(cancelling: session)
        defer { endBackgroundTask() }

        let t0 = Date()
        do {
            let r = try await offMain {
                try session.generateNotes(vault: vault, modelId: modelID, scrub: scrub)
            }
            result = r
            verification = r.verification
        } catch {
            if interruptedInBackground, case CoreError.Cancelled = error {
                self.error = Self.interruptedMessage
            } else {
                self.error = describe(error)
            }
            verification = session.notesStatus().lastVerification
        }
        wallMs = UInt64(Date().timeIntervalSince(t0) * 1000)
        poller.cancel()
        status = nil
        // A rejected key is recorded as used-up credit by the core.
        if result == nil { await refreshCredit(vault: vault) }
    }

    /// Ask iOS for background time so switching apps does not drop the
    /// attested request. If the time runs out, cancel the request (the core
    /// keeps the transcript) and end the task before iOS suspends us.
    private func beginBackgroundTask(cancelling session: Session) {
        interruptedInBackground = false
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Private cloud notes") { [weak self] in
            // UIKit calls the expiration handler on the main thread.
            MainActor.assumeIsolated {
                self?.interruptedInBackground = true
                session.cancelNotes()   // non-blocking: wakes the request so it returns Cancelled
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func cancel(session: Session) {
        Task.detached { session.cancelNotes() }
    }

    func clear() {
        result = nil
        error = nil
        wallMs = nil
        verification = nil
        status = nil
    }
}

extension CheckOutcome {
    var symbol: String {
        switch self {
        case .passed: "checkmark.seal.fill"
        case .unread: "questionmark.circle"
        case .failed: "xmark.octagon.fill"
        case .notRun: "minus.circle"
        }
    }

    var title: String {
        switch self {
        case .passed: "Passed"
        case .unread: "Unread"
        case .failed: "Failed"
        case .notRun: "Not run"
        }
    }
}
