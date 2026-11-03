import SwiftUI

struct NotebookView: View {
    @Environment(AppModel.self) private var app
    @Environment(VaultLock.self) private var vault
    @State private var notes: [NoteSummary] = []
    @State private var error: String?
    @State private var lockRefused: UnfinishedWork?

    var body: some View {
        Group {
            if vault.state == .unlocked {
                List {
                    if notes.isEmpty {
                        Text("No notes yet.").foregroundStyle(.secondary)
                    }
                    ForEach(notes, id: \.id) { n in
                        NavigationLink(value: n.id) {
                            VStack(alignment: .leading) {
                                Text(n.title)
                                Text(Date(timeIntervalSince1970: Double(n.createdAtMs) / 1000)
                                    .formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                .navigationDestination(for: String.self) { NoteDetailView(id: $0) }
                .refreshable { await load() }
                .task { await load() }
                .toolbar {
                    Button("Lock", systemImage: "lock") { lockRefused = app.lock() }
                }
                .alert("Notebook not locked",
                       isPresented: Binding(get: { lockRefused != nil }, set: { if !$0 { lockRefused = nil } }),
                       presenting: lockRefused) { _ in
                    Button("Discard session and lock", role: .destructive) {
                        app.discardSessionAndLock()
                        lockRefused = nil
                    }
                    Button("Keep working", role: .cancel) { lockRefused = nil }
                } message: { work in
                    Text(work.lockRefusal)
                }
            } else {
                VaultGateView()
            }
        }
        .navigationTitle("Notebook")
    }

    private func load() async {
        do {
            notes = try await vault.listNotes().sorted { $0.createdAtMs > $1.createdAtMs }
            error = nil
        } catch {
            self.error = describe(error)
        }
    }
}

struct NoteDetailView: View {
    @Environment(VaultLock.self) private var vault
    let id: String
    @State private var body_: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let body_ {
                Text(markdown(body_)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            } else if let error {
                Text(error).foregroundStyle(.red).padding()
            } else {
                ProgressView().padding()
            }
        }
        .task {
            do { body_ = try await vault.readNote(id: id) } catch { self.error = describe(error) }
        }
    }
}

/// Create or unlock the notebook. Face ID (device passcode as fallback) is the only way in.
struct VaultGateView: View {
    @Environment(VaultLock.self) private var vault
    @State private var confirmStartOver = false

    var body: some View {
        Form {
            switch vault.state {
            case .noVault:
                Section {
                    Button("Create notebook") { Task { await vault.create() } }
                        .disabled(vault.busy || vault.createBlocker != nil)
                } header: {
                    Text("Create notebook")
                } footer: {
                    if let blocker = vault.createBlocker {
                        Text(blocker)
                    } else {
                        Text("Notes are encrypted with a key that never leaves this iPhone. "
                             + "Only Face ID or your device passcode can unlock it. If you remove "
                             + "your passcode, iOS erases the key and these notes can't be opened.")
                    }
                }
            case .locked:
                Section("Notebook locked") {
                    Button {
                        Task { await vault.unlock() }
                    } label: {
                        Label("Unlock", systemImage: "faceid")
                    }
                    .disabled(vault.busy)
                }
            case .keyLost:
                Section {
                    Button("Start a new notebook", role: .destructive) { confirmStartOver = true }
                } header: {
                    Text("Notebook can't be opened")
                } footer: {
                    Text("This notebook's key is no longer on this device (for example, the device "
                         + "passcode was turned off). It can't be opened here. You can start a new "
                         + "notebook; the old one is kept, set aside, not deleted.")
                }
            case .unlocked:
                EmptyView()
            }
            if vault.busy { ProgressView() }
            if let err = vault.error {
                Section { Text(err).foregroundStyle(.red).font(.callout) }
            }
        }
        .confirmationDialog("Start a new notebook?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Set old notebook aside and start over", role: .destructive) {
                vault.setAsideAndStartOver()
            }
        } message: {
            Text("The old notebook file is moved aside and kept. Its notes stay unreadable.")
        }
        .task {
            if vault.state == .locked { await vault.unlock() }
        }
    }
}
