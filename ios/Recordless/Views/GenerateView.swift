import SwiftUI

/// Notes from the private cloud. The scrubbed transcript goes only to a NEAR AI
/// model in a TEE whose attestation passed on the same connection; this screen
/// chooses what to scrub and which model, and shows what was verified.
struct GenerateView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(NotesGenerator.self) private var gen
    @Environment(VaultLock.self) private var vault
    @State private var title = ""
    @State private var savedID: String?
    @State private var saveError: String?
    @State private var showVaultGate = false
    @State private var activationCode = ""
    @State private var pendingScrubOff: ScrubCategory?

    private var canGenerate: Bool {
        !gen.running && recorder.phase == .stopped && recorder.session != nil
            && vault.vault != nil && gen.credit?.active == true
    }

    var body: some View {
        List {
            if recorder.phase != .stopped || recorder.session == nil {
                Section {
                    Text("Record and stop a meeting first.").foregroundStyle(.secondary)
                }
            }

            if vault.vault == nil {
                Section {
                    Button {
                        showVaultGate = true
                    } label: {
                        Label("Unlock notebook", systemImage: "lock.open")
                    }
                } footer: {
                    Text("Your private cloud activation is stored in the notebook, so unlock it to write notes.")
                }
            } else {
                creditSection
                modelSection
            }

            scrubSection

            Section {
                Button {
                    guard let s = recorder.session, let v = vault.vault else { return }
                    savedID = nil
                    Task { await gen.generate(session: s, vault: v) }
                } label: {
                    HStack {
                        Label("Write notes in the private cloud", systemImage: "lock.shield")
                        Spacer()
                        if gen.running { ProgressView() }
                    }
                }
                .disabled(!canGenerate)
                if gen.running, let s = recorder.session {
                    if let st = gen.status, let step = st.step {
                        VStack(alignment: .leading, spacing: 2) {
                            if st.requests > 1 {
                                Text("Request \(st.request) of \(st.requests)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(step).font(.callout)
                        }
                    }
                    Button("Cancel", role: .cancel) { gen.cancel(session: s) }
                }
            } footer: {
                Text("Nothing but attestation evidence is sent until every check passes on the connection that carries the notes request. A failed or cancelled request keeps the transcript so you can retry.")
            }

            if let err = gen.error {
                Section { Text(err).foregroundStyle(.red).font(.callout) }
            }

            if let report = gen.verification {
                VerificationSection(report: report)
            }

            if let r = gen.result {
                Section("Run") {
                    StatRow(label: "Model", value: r.modelId)
                    StatRow(label: "Elapsed", value: Format.duration(ms: r.elapsedMs))
                    StatRow(label: "Attested requests", value: "\(r.requests)")
                    StatRow(label: "Prompt / generated tokens", value: "\(r.promptTokens) / \(r.generatedTokens)")
                }
                Section("Notes") {
                    Text(markdown(r.markdown)).textSelection(.enabled)
                }
                Section("Save") {
                    TextField("Title", text: $title)
                    Button {
                        Task { await save(r.markdown) }
                    } label: {
                        Label(savedID == nil ? "Save to notebook" : "Saved",
                              systemImage: savedID == nil ? "lock.doc" : "checkmark")
                    }
                    .disabled(savedID != nil)
                    if let saveError { Text(saveError).foregroundStyle(.red).font(.callout) }
                }
            }
        }
        .navigationTitle("Notes")
        .sheet(isPresented: $showVaultGate) {
            NavigationStack { VaultGateView() }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            pendingScrubOff.map { "Stop scrubbing \($0.noun)?" } ?? "",
            isPresented: Binding(get: { pendingScrubOff != nil }, set: { if !$0 { pendingScrubOff = nil } }),
            titleVisibility: .visible,
            presenting: pendingScrubOff
        ) { category in
            Button("Send \(category.noun) unscrubbed", role: .destructive) {
                set(category, scrub: false)
                pendingScrubOff = nil
            }
            Button("Keep scrubbing", role: .cancel) { pendingScrubOff = nil }
        } message: { category in
            Text("\(category.noun.capitalized) in this meeting will no longer be removed before the transcript is sent to the private cloud enclave (NEAR AI, verified TEE), and may appear in the notes.")
        }
        .task(id: vault.vault.map(ObjectIdentifier.init)) {
            if let v = vault.vault { await gen.refresh(vault: v) }
        }
        .onChange(of: recorder.session.map(ObjectIdentifier.init)) { _, _ in
            if let s = recorder.session { gen.prepare(for: s) }
        }
        .onAppear {
            if let s = recorder.session { gen.prepare(for: s) }
        }
        .onChange(of: vault.state) { _, s in
            if s == .unlocked { showVaultGate = false }
        }
    }

    // MARK: Sections

    @ViewBuilder private var creditSection: some View {
        Section {
            if let c = gen.credit {
                StatRow(label: "Private cloud", value: creditSummary(c))
                if c.active && c.creditUsedUp {
                    if c.paymentPending { Text("A payment is being added to your credit.").font(.callout) }
                    if c.disabled { Text("This activation code was turned off.").font(.callout).foregroundStyle(.red) }
                    if let exp = c.expiresAt { StatRow(label: "Expires", value: exp) }
                    if let s = c.upgradeUrl, let url = URL(string: s) {
                        Link(destination: url) { Label("Add credit", systemImage: "creditcard") }
                    }
                    if let e = c.checkError { Text(e).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if gen.credit?.active != true || gen.credit?.creditUsedUp == true {
                HStack {
                    TextField("Activation code", text: $activationCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    Button {
                        guard let v = vault.vault else { return }
                        Task {
                            if await gen.redeem(code: activationCode, vault: v) {
                                activationCode = ""
                                await gen.loadModels(vault: v)
                            }
                        }
                    } label: {
                        if gen.redeeming { ProgressView() } else { Text("Activate") }
                    }
                    .disabled(activationCode.trimmingCharacters(in: .whitespaces).isEmpty || gen.redeeming)
                }
            }
            if let e = gen.creditError { Text(e).foregroundStyle(.red).font(.callout) }
        } header: {
            Text("Private cloud credit")
        } footer: {
            if gen.credit?.available == false && gen.credit?.active != true {
                Text("Activation codes aren't available in this build.")
            } else {
                Text("The code is exchanged for a capped NEAR AI key, kept in your notebook and never shown. Recordless's credit service never sees meeting content.")
            }
        }
    }

    private func creditSummary(_ c: CreditStatus) -> String {
        if !c.active { return "Not activated" }
        if c.creditUsedUp { return "Credit used up" }
        return c.ownKey ? "Active (own key)" : "Active"
    }

    @ViewBuilder private var modelSection: some View {
        @Bindable var gen = gen
        Section {
            if gen.models.isEmpty {
                HStack {
                    Text(gen.loadingModels ? "Loading models…" : "No models listed").foregroundStyle(.secondary)
                    Spacer()
                    if gen.loadingModels { ProgressView() }
                }
            } else {
                Picker("Model", selection: Binding(
                    get: { gen.effectiveModel?.id ?? "" },
                    set: { gen.selectedModelID = $0 })) {
                    ForEach(gen.models, id: \.id) { m in
                        Text(m.suggestionLabel.map { "\(m.displayName) · \($0)" } ?? m.displayName).tag(m.id)
                    }
                }
                if let m = gen.effectiveModel {
                    if let reason = m.suggestionReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if let i = m.inputPrice, let o = m.outputPrice {
                        Text(String(format: "$%.2f in / $%.2f out per million tokens", i, o))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let e = gen.modelsError { Text(e).foregroundStyle(.red).font(.caption) }
            if let v = vault.vault {
                Button("Refresh model list") { Task { await gen.loadModels(vault: v) } }
                    .disabled(gen.loadingModels)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Listed from NEAR AI's TEE host list. Every model is attested before anything is sent.")
        }
    }

    @ViewBuilder private var scrubSection: some View {
        Section {
            ForEach(ScrubCategory.allCases) { category in
                Toggle(category.label, isOn: Binding(
                    get: { isScrubbed(category) },
                    set: { on in
                        if on { set(category, scrub: true) } else { pendingScrubOff = category }
                    }))
            }
        } header: {
            Text("Scrub before sending")
        } footer: {
            Text(gen.scrubsEverything
                 ? "Removed on this device before the transcript leaves it. Names are kept out by the notes instructions, since they can't be matched by pattern."
                 : "Some categories are not scrubbed: they go to the private cloud enclave as spoken.")
        }
        .disabled(gen.running)
    }

    private func isScrubbed(_ c: ScrubCategory) -> Bool {
        switch c {
        case .emails: gen.scrubEmails
        case .phones: gen.scrubPhones
        case .urls: gen.scrubUrls
        case .numbers: gen.scrubNumbers
        case .names: gen.scrubNames
        }
    }

    private func set(_ c: ScrubCategory, scrub: Bool) {
        switch c {
        case .emails: gen.scrubEmails = scrub
        case .phones: gen.scrubPhones = scrub
        case .urls: gen.scrubUrls = scrub
        case .numbers: gen.scrubNumbers = scrub
        case .names: gen.scrubNames = scrub
        }
    }

    private func save(_ md: String) async {
        saveError = nil
        guard vault.state == .unlocked else {
            showVaultGate = true
            return
        }
        let t = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : title
        do {
            savedID = try await vault.saveNote(title: t, markdown: md)
            // As on desktop, saving keeps the notes and releases the transcript.
            recorder.session?.markNotesSaved()
            recorder.discard()
        } catch {
            saveError = describe(error)
        }
    }
}

enum ScrubCategory: String, CaseIterable, Identifiable {
    case names, emails, phones, urls, numbers
    var id: String { rawValue }

    var label: String {
        switch self {
        case .names: "Names and personal details"
        case .emails: "Email addresses"
        case .phones: "Phone numbers"
        case .urls: "Links"
        case .numbers: "ID, card and account numbers"
        }
    }

    var noun: String {
        switch self {
        case .names: "names and personal details"
        case .emails: "email addresses"
        case .phones: "phone numbers"
        case .urls: "links"
        case .numbers: "ID, card and account numbers"
        }
    }
}

/// A one-line verdict that expands into every check.
private struct VerificationSection: View {
    let report: VerificationReport
    @State private var expanded = false

    private var counts: (passed: Int, unread: Int, failed: Int) {
        (report.checks.filter { $0.outcome == .passed }.count,
         report.checks.filter { $0.outcome == .unread }.count,
         report.checks.filter { $0.outcome == .failed }.count)
    }

    var body: some View {
        Section("Secure enclave verification") {
            DisclosureGroup(isExpanded: $expanded) {
                if let host = report.host { StatRow(label: "Host", value: host) }
                if let tcb = report.tcbStatus { StatRow(label: "Intel TDX status", value: tcb) }
                if report.attestedRequests > 1 {
                    StatRow(label: "Attested requests", value: "\(report.attestedRequests)")
                }
                ForEach(report.checks, id: \.id) { check in
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(check.label)
                        } icon: {
                            Image(systemName: check.outcome.symbol).foregroundStyle(color(check.outcome))
                        }
                        Text(check.outcome.title + (check.detail.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } label: {
                let c = counts
                Label {
                    VStack(alignment: .leading) {
                        Text(report.passed ? "Verified" : "Not verified").font(.body.weight(.medium))
                        Text("\(c.passed) passed" + (c.unread > 0 ? ", \(c.unread) unread" : "")
                             + (c.failed > 0 ? ", \(c.failed) failed" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: report.passed ? "lock.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(report.passed ? .green : .red)
                }
            }
        }
    }

    private func color(_ o: CheckOutcome) -> Color {
        switch o {
        case .passed: .green
        case .unread: .orange
        case .failed: .red
        case .notRun: .secondary
        }
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}
