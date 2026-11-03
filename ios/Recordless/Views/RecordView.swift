import SwiftUI

struct RecordView: View {
    @Environment(Recorder.self) private var recorder
    @Environment(ModelStore.self) private var store
    @AppStorage("record.speechModel") private var speechModelID = ModelSpec.whisperBase.id
    @AppStorage("record.useGpu") private var useGpu = true

    private var speechModels: [ModelSpec] { store.ready(.speech) }
    private var selected: ModelSpec? {
        speechModels.first { $0.id == speechModelID } ?? speechModels.first
    }

    var body: some View {
        List {
            if recorder.phase == .idle {
                Section("Setup") {
                    if speechModels.isEmpty {
                        Text("Download a speech model in the Models tab first.").foregroundStyle(.secondary)
                    } else {
                        Picker("Speech model", selection: $speechModelID) {
                            ForEach(speechModels) { Text($0.title).tag($0.id) }
                        }
                        Toggle("Use GPU (Metal)", isOn: $useGpu)
                    }
                }
            }

            Section {
                VStack(spacing: 16) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Format.duration(seconds: recorder.elapsed))
                            .font(.system(size: 56, weight: .light, design: .rounded))
                            .monospacedDigit()
                    }
                    LevelMeter(level: recorder.level, active: recorder.phase == .recording)
                    statusLine
                    controls
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                Text("Audio is processed in memory and never saved. The transcript is never shown or stored — only counts and timings appear here.")
            }

            if let p = recorder.progress {
                Section("Session") {
                    StatRow(label: "Segments", value: "\(p.segments)")
                    StatRow(label: "Speech captured", value: Format.duration(ms: p.speechMs))
                    StatRow(label: "Waiting to transcribe", value: Format.duration(ms: p.pendingMs))
                    if p.incomplete {
                        Label("Some audio failed to transcribe; partial transcript kept.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if let s = recorder.speechStats, s.realtimeFactor > 0 {
                        StatRow(label: "Realtime factor", value: String(format: "%.1f×", s.realtimeFactor))
                    }
                }
            }

            if let err = recorder.lastError {
                Section { Text(err).foregroundStyle(.red).font(.callout) }
            }
        }
        .navigationTitle("Record")
    }

    @ViewBuilder private var statusLine: some View {
        switch recorder.phase {
        case .idle: Text("Ready").foregroundStyle(.secondary)
        case .loadingModel: Label("Loading speech model…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .recording:
            if recorder.interrupted {
                Label("Paused by the system (call or Siri)", systemImage: "pause.circle").foregroundStyle(.orange)
            } else {
                VStack(spacing: 4) {
                    let p = recorder.progress
                    let segments = p?.segments ?? 0
                    if p?.transcribing == true {
                        Label("Transcribing…", systemImage: "text.bubble").foregroundStyle(.blue)
                    } else if p?.inSpeech == true {
                        Label("Hearing speech…", systemImage: "waveform").foregroundStyle(.red)
                    } else {
                        Label("Listening", systemImage: "ear").foregroundStyle(.red)
                    }
                    Text(segments == 1 ? "1 segment transcribed" : "\(segments) segments transcribed")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    if let hint = quietHint {
                        Text(hint).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    }
                }
            }
        case .stopping: Label("Finishing transcription…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .stopped: Label("Meeting captured. Generate notes in the Notes tab.", systemImage: "checkmark.circle")
            .foregroundStyle(.green)
        }
    }

    /// After ~10 s of capture with no speech detected, say why.
    private var quietHint: String? {
        guard let d = recorder.diagnostics, let c = recorder.captureStats else { return nil }
        if c.buffers > 20 && d.samplesReceived == 0 {
            return "The microphone delivers audio but none reaches the transcriber (\(c.emptyConversions) empty conversions). See Bench."
        }
        guard d.samplesReceived > 16_000 * 10, d.vadSpeechFrames == 0 else { return nil }
        return "No speech detected yet (input \(d.levelDbfs) dBFS, needs \(d.thresholdDbfs)). Move closer or speak up."
    }

    @ViewBuilder private var controls: some View {
        switch recorder.phase {
        case .idle:
            Button {
                guard let spec = selected else { return }
                Task { await recorder.start(speechModel: store.fileURL(spec), useGpu: useGpu) }
            } label: {
                Label("Start", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            .disabled(selected == nil)
        case .loadingModel, .stopping:
            ProgressView()
        case .recording:
            Button {
                Task { await recorder.stop() }
            } label: {
                Label("Stop", systemImage: "stop.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        case .stopped:
            Button(role: .destructive) { recorder.discard() } label: {
                Label("Discard meeting", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool
    private let bars = 20

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let lit = active && Float(i + 1) / Float(bars) <= level + 0.001
                RoundedRectangle(cornerRadius: 2)
                    .fill(lit ? color(i) : Color.secondary.opacity(0.2))
                    .frame(height: 18)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(_ i: Int) -> Color {
        let f = Double(i) / Double(bars)
        return f > 0.85 ? .red : f > 0.65 ? .orange : .green
    }
}
