import SwiftUI
import os

struct BenchmarksView: View {
    /// Mic path, VAD and whisper counters from the latest recording: where
    /// audio stops if no segments appear. Counts and coarse levels only.
    @ViewBuilder private var micSection: some View {
        Section {
            if let c = recorder.captureStats {
                StatRow(label: "Mic input", value: "\(Int(c.inputSampleRate)) Hz · \(c.inputChannels) ch")
                StatRow(label: "Buffers / frames in", value: "\(c.buffers) / \(c.framesIn)")
                StatRow(label: "Converted rate", value: "\(Int(c.convertedRate.rounded())) Hz")
                StatRow(label: "Empty / failed conversions", value: "\(c.emptyConversions) / \(c.conversionErrors)")
                StatRow(label: "Mic level", value: "\(c.levelDb) dBFS")
            }
            if let d = recorder.diagnostics {
                StatRow(label: "Samples pushed", value: "\(d.samplesReceived) (\(Format.duration(ms: d.samplesReceived / 16)))")
                StatRow(label: "VAD speech / frames", value: "\(d.vadSpeechFrames) / \(d.vadFrames)")
                StatRow(label: "Level / noise / threshold", value: "\(d.levelDbfs) / \(d.noiseFloorDbfs) / \(d.thresholdDbfs) dB")
                StatRow(label: "Utterances (dropped)", value: "\(d.utterances) (\(d.utterancesDropped))")
                StatRow(label: "Whisper runs / failed / empty", value: "\(d.inferenceRuns) / \(d.inferenceFailures) / \(d.emptyResults)")
                StatRow(label: "Last inference", value: "\(d.lastInferenceMs) ms")
                if d.gpuFallback { StatRow(label: "GPU", value: "failed, moved to CPU") }
                if d.speechUnavailable { StatRow(label: "Speech model", value: "CPU reload failed; rest not transcribed") }
            }
            if recorder.captureStats == nil && recorder.diagnostics == nil {
                Text("Record something to see the microphone path.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Microphone path")
        } footer: {
            Text("Counts and levels only. Speech needs the level above the threshold; segments appear after a pause.")
        }
    }

    @Environment(Recorder.self) private var recorder
    @Environment(NotesGenerator.self) private var gen
    @State private var footprint: UInt64 = 0
    @State private var peak: UInt64 = 0
    @State private var available: Int = 0
    @State private var version = ""
    @AppStorage(GPUSettings.speechKey) private var speechUseGpu = false

    var body: some View {
        @Bindable var gen = gen
        List {
            Section {
                Toggle("Speech on GPU (Metal)", isOn: $speechUseGpu)
                    .disabled(recorder.phase != .idle)
                Toggle("On-device notes on GPU (Metal)", isOn: $gen.localUseGpu)
                    .disabled(gen.running)
            } header: {
                Text("Settings")
            } footer: {
                Text("Off by default, as on desktop: memory the CPU used is wiped when freed, GPU memory can't be. The GPU is faster. iOS refuses GPU work in the background, so a GPU run then moves to the CPU. Speech applies from the next recording.")
            }
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
            micSection
            Section("Notes") {
                if let r = gen.result {
                    StatRow(label: "Where", value: r.location == .onDevice ? "On this device" : "Private cloud")
                    StatRow(label: "Elapsed (core)", value: "\(r.elapsedMs) ms")
                    if let w = gen.wallMs { StatRow(label: "Wall time", value: "\(w) ms") }
                    StatRow(label: r.location == .onDevice ? "Requests" : "Attested requests", value: "\(r.requests)")
                    StatRow(label: "Prompt / generated", value: "\(r.promptTokens) / \(r.generatedTokens)")
                    if let l = r.local {
                        StatRow(label: "Model load", value: "\(l.loadMs) ms")
                        StatRow(label: "Prefill", value: String(format: "%.0f tokens/s", l.promptTokensPerS))
                        StatRow(label: "Generation", value: String(format: "%.1f tokens/s", l.tokensPerS))
                        StatRow(label: "Peak footprint", value: Format.bytes(l.peakFootprintBytes))
                        StatRow(label: "Context / backend",
                                value: "\(l.contextTokens) · \(l.gpu ? (l.gpuFallback ? "GPU, then CPU" : "GPU") : "CPU")")
                    }
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
