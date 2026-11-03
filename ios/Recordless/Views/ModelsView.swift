import SwiftUI

struct ModelsView: View {
    @Environment(ModelStore.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(ModelSpec.all.filter { $0.kind == .speech }) { ModelRow(spec: $0) }
            } header: {
                Text("Speech")
            } footer: {
                Text("Speech models run on this device and are excluded from iCloud backup. Downloads continue in the background.")
            }
            Section {
                ForEach(ModelSpec.all.filter { $0.kind == .notes && $0.fitsDevice }) { ModelRow(spec: $0) }
            } header: {
                Text("Notes")
            } footer: {
                Text("Notes are written on this iPhone by default, with this model; nothing leaves the device. "
                     + (ModelSpec.qwen4B.fitsDevice ? "" : "The 4B model needs 8 GB of RAM and isn't offered on this iPhone. ")
                     + "The private cloud (a verified secure enclave) is an option on the Notes screen and needs no download.")
            }
        }
        .navigationTitle("Models")
        .onAppear { store.refreshFromDisk() }
    }
}

private struct ModelRow: View {
    @Environment(ModelStore.self) private var store
    let spec: ModelSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(spec.title).font(.body.weight(.medium))
                    Text(spec.fileName + (spec.optional ? " · optional" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            if case .downloading(let r, let e) = store.status[spec.id] ?? .missing {
                let total = e > 0 ? e : Int64(spec.approxBytes)
                ProgressView(value: Double(r), total: Double(max(total, 1)))
                Text("\(Format.bytes(UInt64(max(r, 0)))) of \(Format.bytes(UInt64(max(total, 0))))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if case .failed(let msg) = store.status[spec.id] ?? .missing {
                Text(msg).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var action: some View {
        switch store.status[spec.id] ?? .missing {
        case .missing, .failed:
            Button("Get · ~\(Format.bytes(spec.approxBytes))") { store.download(spec) }
                .buttonStyle(.bordered)
        case .downloading:
            Button("Cancel", role: .cancel) { store.cancel(spec) }.buttonStyle(.bordered)
        case .verifying:
            ProgressView().accessibilityLabel("Verifying")
        case .ready(let bytes):
            Menu {
                Button("Delete", role: .destructive) { store.delete(spec) }
            } label: {
                Label(Format.bytes(bytes), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
