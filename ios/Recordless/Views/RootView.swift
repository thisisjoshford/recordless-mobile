import SwiftUI

/// Designed UI: Unlock, then the Listen / Notes / Settings tabs.
struct RootView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        Group {
            if flow.locked {
                UnlockView()
                    .transition(.opacity)
            } else {
                MainTabs()
            }
        }
        .tint(Theme.primary)
        .animation(.easeOut(duration: 0.2), value: flow.locked)
    }
}

private struct MainTabs: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        TabView(selection: $flow.tab) {
            Tab("Listen", systemImage: "waveform", value: MainTab.listen) {
                NavigationStack(path: $flow.listenPath) {
                    HomeView().navigationDestination(for: UUID.self) { NoteView(noteID: $0) }
                }
            }
            Tab("Notes", systemImage: "doc.text", value: MainTab.notes) {
                NavigationStack(path: $flow.notesPath) {
                    NotesListView().navigationDestination(for: UUID.self) { NoteView(noteID: $0) }
                }
            }
            Tab("Settings", systemImage: "gearshape", value: MainTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .fullScreenCover(isPresented: $flow.livePresented, onDismiss: flow.liveDismissed) {
            LiveSessionView()
        }
    }
}

/// Placeholder: Settings contents are not designed yet. Developer tools keep
/// the phase-0 spike screens (model downloads, benchmarks) reachable.
private struct SettingsView: View {
    @State private var showingTools = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(Theme.font(Theme.Size.largeTitle, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text("Settings aren't designed yet.")
                    .font(Theme.font(Theme.Size.row))
                    .foregroundStyle(Theme.mutedForeground)
                SectionLabel("Developer").padding(.top, 8)
                SecondaryButton(title: "Developer tools", systemImage: "wrench.and.screwdriver") {
                    showingTools = true
                }
            }
            .padding(.horizontal, Theme.Spacing.screenSide)
            .padding(.top, Theme.Spacing.topInset)
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle("Settings")
        .fullScreenCover(isPresented: $showingTools) { DeveloperToolsView() }
    }
}

/// The phase-0 spike tabs, unchanged.
struct DeveloperToolsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            Tab("Models", systemImage: "arrow.down.circle", value: AppTab.models) { tools { ModelsView() } }
            Tab("Capture", systemImage: "waveform", value: AppTab.record) { tools { RecordView() } }
            Tab("Notes", systemImage: "sparkles", value: AppTab.notes) { tools { GenerateView() } }
            Tab("Notebook", systemImage: "book.closed", value: AppTab.notebook) { tools { NotebookView() } }
            Tab("Bench", systemImage: "speedometer", value: AppTab.bench) { tools { BenchmarksView() } }
        }
    }

    private func tools(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            content().toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
    }
}

enum AppTab: Hashable { case models, record, notes, notebook, bench }

/// Covers the UI whenever the scene is not active so the app-switcher snapshot is blank.
struct PrivacyOverlay: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                LogoView(size: 72)
                Text("Recordless").font(Theme.wordmark(34)).foregroundStyle(Theme.foreground)
            }
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
