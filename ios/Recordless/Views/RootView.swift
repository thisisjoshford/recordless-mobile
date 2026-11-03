import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Models", systemImage: "arrow.down.circle") { NavigationStack { ModelsView() } }
            Tab("Record", systemImage: "waveform") { NavigationStack { RecordView() } }
            Tab("Notes", systemImage: "sparkles") { NavigationStack { GenerateView() } }
            Tab("Notebook", systemImage: "book.closed") { NavigationStack { NotebookView() } }
            Tab("Bench", systemImage: "speedometer") { NavigationStack { BenchmarksView() } }
        }
    }
}

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
