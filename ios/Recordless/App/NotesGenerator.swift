import Foundation
import Observation
import UIKit

/// Where notes are written. On this device is the default (as on desktop).
enum NotesWhere: String, CaseIterable, Identifiable {
    case onDevice, privateCloud
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onDevice: "On this device"
        case .privateCloud: "Private cloud"
        }
    }
}

/// Notes on this device (llama.cpp in the core, the default) or from the
/// private cloud: the core scrubs the transcript the same way for both, and
/// sends it only to a NEAR AI model whose TEE attestation passed on the same
/// TLS connection. The transcript never reaches Swift, and neither does the
/// NEAR AI key (it lives in the vault). Swift sees the notes, counts, timings
/// and what was verified.
@Observable
@MainActor
final class NotesGenerator {
    var location: NotesWhere {
        didSet { UserDefaults.standard.set(location.rawValue, forKey: Self.locationKey) }
    }
    private static let locationKey = "generate.location"
    /// On-device notes model (a ModelSpec id).
    var localModelID: String {
        didSet { UserDefaults.standard.set(localModelID, forKey: Self.localModelKey) }
    }
    private static let localModelKey = "generate.localModel"
    /// Off by default (as on desktop: GPU memory can't be wiped).
    var localUseGpu: Bool {
        didSet { UserDefaults.standard.set(localUseGpu, forKey: GPUSettings.notesKey) }
    }

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
    /// Bumped when a request starts and ends, so a status poll still in
    /// flight from an earlier run (or after this one ended) is dropped.
    @ObservationIgnored private var runToken = 0
    /// Keeps the request running for a while after the user switches apps.
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// iOS ran out of background time and the request was cancelled.
    @ObservationIgnored private var interruptedInBackground = false
    /// Called (on main) when a request ends: success, failure or cancellation.
    @ObservationIgnored var onFinished: (() -> Void)?

    static let interruptedMessage =
        "Notes were interrupted because iOS stopped the app in the background. "
        + "The transcript is kept: tap Write notes to retry."

    init() {
        let d = UserDefaults.standard
        selectedModelID = d.string(forKey: Self.modelKey)
        location = d.string(forKey: Self.locationKey).flatMap(NotesWhere.init(rawValue:)) ?? .onDevice
        localModelID = d.string(forKey: Self.localModelKey) ?? ModelSpec.qwen2B.id
        localUseGpu = d.bool(forKey: GPUSettings.notesKey)
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

    /// Private cloud notes.
    /// `instructions`: the person's style request from Edit template, if any.
    func generate(session: Session, vault: Vault, instructions: String? = nil) async {
        let scrub = self.scrub
        let modelID = effectiveModel?.id ?? selectedModelID
        await run(session: session, taskName: "Private cloud notes") {
            try session.generateNotes(vault: vault, modelId: modelID, scrub: scrub, instructions: instructions)
        }
        // A rejected key is recorded as used-up credit by the core.
        if result == nil { await refreshCredit(vault: vault) }
    }

    /// On-device notes with the GGUF at `model`. The screen is kept awake
    /// while it runs: the background time iOS grants is short, and it refuses
    /// GPU work there (the core then moves a GPU run to the CPU).
    func generateOnDevice(session: Session, model: URL, useGpu: Bool, instructions: String? = nil) async {
        let scrub = self.scrub
        let path = model.path
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled }
        await run(session: session, taskName: "On-device notes") {
            try session.generateNotesOnDevice(modelPath: path, useGpu: useGpu, scrub: scrub, instructions: instructions)
        }
    }

    private func run(session: Session, taskName: String,
                     _ work: @escaping @Sendable () throws -> NotesResult) async {
        guard !running else { return }
        running = true
        runToken += 1
        let token = runToken
        error = nil
        result = nil
        status = nil
        verification = nil
        defer {
            running = false
            onFinished?()
        }

        // Poll the core's step labels while the request runs. A poll that
        // returns after this run ended (or another began) is dropped.
        let poller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let s = await Task.detached { session.notesStatus() }.value
                guard let self, !Task.isCancelled, self.runToken == token else { return }
                self.status = s
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        beginBackgroundTask(named: taskName, cancelling: session)
        defer { endBackgroundTask() }

        let t0 = Date()
        do {
            let r = try await offMain(work)
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
        runToken += 1
        poller.cancel()
        status = nil
    }

    /// Ask iOS for background time so switching apps does not drop the
    /// attested request. If the time runs out, cancel the request (the core
    /// keeps the transcript) and end the task before iOS suspends us.
    private func beginBackgroundTask(named name: String, cancelling session: Session) {
        interruptedInBackground = false
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
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
