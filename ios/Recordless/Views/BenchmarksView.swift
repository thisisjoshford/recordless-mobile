import SwiftUI
import os

struct BenchmarksView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(NotesGenerator.self) private var gen
    @State private var footprint: UInt64 = 0
    @State private var peak: UInt64 = 0
    @State private var available: Int = 0
    @State private var version = ""

    var body: some View {
        List {
            Section("Memory (live)") {
                StatRow(label: "phys_footprint", value: Format.bytes(footprint))
                StatRow(label: "Peak footprint", value: Format.bytes(peak))
                StatRow(label: "Available to app", value: Format.bytes(UInt64(max(available, 0))))
                StatRow(label: "Device RAM", value: Format.bytes(ProcessInfo.processInfo.physicalMemory))
            }
            Section("Speech") {
                StatRow(label: "Model load (wall)", value: recorder.modelLoadMs.map { "\($0) ms" } ?? "—")
                StatRow(label: "Model load (core)", value: recorder.speechStats.map { "\($0.loadMs) ms" } ?? "—")
                StatRow(label: "Realtime factor",
                        value: recorder.speechStats.map { String(format: "%.2f×", $0.realtimeFactor) } ?? "—")
                if let p = recorder.progress {
                    StatRow(label: "Speech / pending",
                            value: "\(Format.duration(ms: p.speechMs)) / \(Format.duration(ms: p.pendingMs))")
                }
                if recorder.pushErrors > 0 {
                    StatRow(label: "push_audio errors", value: "\(recorder.pushErrors)")
                }
            }
            Section("Private cloud notes") {
                if let r = gen.result {
                    StatRow(label: "Elapsed (core)", value: "\(r.elapsedMs) ms")
                    if let w = gen.wallMs { StatRow(label: "Wall time", value: "\(w) ms") }
                    StatRow(label: "Attested requests", value: "\(r.requests)")
                    StatRow(label: "Prompt / generated", value: "\(r.promptTokens) / \(r.generatedTokens)")
                } else {
                    Text("No run yet").foregroundStyle(.secondary)
                }
            }
            Section("Build") {
                StatRow(label: "Core", value: version)
                StatRow(label: "OS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }
        }
        .navigationTitle("Benchmarks")
        .task {
            version = coreVersion()
            while !Task.isCancelled {
                let (f, p) = await Task.detached { (physFootprintBytes(), peakFootprintBytes()) }.value
                footprint = f
                peak = p
                available = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
