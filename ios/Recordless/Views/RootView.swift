import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Models", systemImage: "arrow.down.circle", value: AppTab.models) { NavigationStack { ModelsView() } }
            Tab("Record", systemImage: "waveform", value: AppTab.record) { NavigationStack { RecordView() } }
            Tab("Notes", systemImage: "sparkles", value: AppTab.notes) { NavigationStack { GenerateView() } }
            Tab("Notebook", systemImage: "book.closed", value: AppTab.notebook) { NavigationStack { NotebookView() } }
            Tab("Bench", systemImage: "speedometer", value: AppTab.bench) { NavigationStack { BenchmarksView() } }
        }
    }
}

enum AppTab: Hashable { case models, record, notes, notebook, bench }

/// Covers the UI whenever the scene is not active so the app-switcher snapshot is blank.
struct PrivacyOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                Text("Recordless").font(.title2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        LabeledContent(label) {
            Text(value).monospacedDigit().foregroundStyle(.primary)
        }
    }
}
