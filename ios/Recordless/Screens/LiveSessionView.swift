import SwiftUI

/// SPEC 3, `Live.dc.html`. Shows counts and states, never words.
struct LiveSessionView: View {
    @Environment(AppFlow.self) private var flow

    var body: some View {
        @Bindable var flow = flow
        let session = flow.session

        VStack(spacing: Theme.Spacing.stackGap) {
            LogoView(size: 72)
            HStack(alignment: .center, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DurationFormat.clock(session.elapsed(at: context.date)))
                        .font(Theme.font(Theme.Size.timer, .bold, relativeTo: .largeTitle))
                        .monospacedDigit()
                        .tracking(-1)
                        .foregroundStyle(Theme.foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel("Elapsed \(DurationFormat.clock(session.elapsed(at: context.date)))")
                }
                Spacer(minLength: 0)
                StatusPill(status: session.status)
            }
            MicLevelCard(level: session.status == .interrupted ? 0 : session.level,
                         active: session.status == .listening || session.status == .transcribing)
            CapturedCard(segments: session.segments)
            if let problem = session.problem {
                Text(problem)
                    .font(Theme.font(Theme.Size.secondary, .semibold))
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            controls(session)
        }
        .padding(.horizontal, Theme.Spacing.screenSide)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .screenBackground()
        .sheet(isPresented: $flow.generatePresented) {
            GenerateNotesSheet()
        }
    }

    @ViewBuilder
    private func controls(_ session: SessionStore) -> some View {
        let paused = session.status == .paused
        let interrupted = session.status == .interrupted
        let busy = session.status != .listening && session.status != .transcribing && !paused && !interrupted
        if session.status == .idle {
            // Didn't start (microphone off, model failed to load).
            PrimaryButton(title: "Close", systemImage: "xmark") { flow.discardSession() }
        } else {
        HStack(spacing: 12) {
            CircleIconButton(systemImage: paused ? "play.fill" : "pause.fill",
                             label: paused ? "Resume" : "Pause",
                             size: Theme.Spacing.primaryButton, iconSize: 20) {
                paused ? session.resume() : session.pause()
            }
            .disabled(busy || interrupted)
            PrimaryButton(title: "End session", systemImage: "stop.fill") {
                Task { await flow.endSession() }
            }
            .disabled(busy)
        }
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let status: SessionStore.Status

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 14)
            Text(label)
        }
        .font(Theme.font(Theme.Size.control, .bold))
        .foregroundStyle(Theme.primary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.infoSoft, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var label: String {
        switch status {
        case .idle: "Not listening"
        case .starting: "Starting…"
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .finishing: "Finishing…"
        case .ended: "Session ended"
        }
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .idle:
            Image(systemName: "mic.slash").font(.system(size: 12, weight: .bold))
        case .listening:
            HStack(alignment: .center, spacing: 2) {
                ForEach([4.0, 10, 14, 6], id: \.self) { h in
                    Capsule().fill(Theme.primary).frame(width: 3, height: h)
                }
            }
        case .transcribing:
            HStack(spacing: 1.5) {
                ForEach([1.0, 0.6, 0.3], id: \.self) { o in
                    Capsule().fill(Theme.primary.opacity(o)).frame(width: 5, height: 2.5)
                }
            }
        case .paused:
            Image(systemName: "pause.fill").font(.system(size: 12, weight: .bold))
        case .interrupted:
            Image(systemName: "mic.slash").font(.system(size: 12, weight: .bold))
        case .starting, .finishing:
            ProgressView().controlSize(.small).tint(Theme.primary)
        case .ended:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
        }
    }
}

// MARK: - Mic level

struct MicLevelCard: View {
    let level: Double
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic").font(.system(size: 14)).foregroundStyle(Theme.foreground)
                    .accessibilityHidden(true)
                Text("iPhone Microphone").font(Theme.font(Theme.Size.secondary, .semibold))
                    .foregroundStyle(Theme.foreground)
                Spacer()
            }
            SegmentedLevelBar(level: active ? level : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardStyle(radius: Theme.Radius.input, shadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(active ? "Microphone on" : "Microphone paused")
    }
}

// MARK: - Captured

/// Segments drawn as blocks. Block counts and widths are pseudo-random per
/// segment, not real words, so nothing about the speech shows.
struct CapturedCard: View {
    let segments: [CapturedSegment]
    private var count: Int { segments.count }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Captured").font(Theme.font(Theme.Size.row, .bold)).foregroundStyle(Theme.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(count.formatted()) \(count == 1 ? "segment" : "segments")")
                        .font(Theme.font(Theme.Size.secondary, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.foreground)
                        .contentTransition(.numericText())
                }
                InMemoryLine(rest: "never written to disk")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            WordBlocks(segments: segments)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            Text("Speech is counted, never shown. The transcript clears when you save notes or discard.")
                .font(Theme.font(Theme.Size.sectionLabel, relativeTo: .caption))
                .foregroundStyle(Theme.mutedForeground)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.largeCard, style: .continuous))
        .cardStyle(radius: Theme.Radius.largeCard)
    }
}

/// Lines fill from the top; once full, the newest line stays at the bottom.
/// New segments draw in word by word (stagger up to 140 ms, at most 2 s per
/// segment), with no stagger under Reduce Motion.
private struct WordBlocks: View {
    let segments: [CapturedSegment]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Segments up to this id are drawn in full. Newer ones draw only the
    /// words `revealed` allows, so a new segment never flashes in full
    /// before its stagger starts.
    @State private var shownThrough = Int.max
    @State private var revealed: (id: Int, count: Int)?

    private static let blockHeight: CGFloat = 10
    private static let lineGap: CGFloat = 9
    private static let wordGap: CGFloat = 5

    var body: some View {
        Canvas { ctx, size in
            let lines = layout(width: size.width)
            let maxLines = max(1, Int((size.height + Self.lineGap) / (Self.blockHeight + Self.lineGap)))
            let visible = lines.suffix(maxLines)
            for (row, line) in visible.enumerated() {
                let y = CGFloat(row) * (Self.blockHeight + Self.lineGap)
                for block in line {
                    let rect = CGRect(x: block.x, y: y, width: block.width, height: Self.blockHeight)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: Theme.Radius.block),
                             with: .color(Theme.primary.opacity(block.opacity)))
                }
            }
        }
        .onAppear { shownThrough = segments.last?.id ?? -1 }    // no stagger for what's already there
        .onChange(of: segments.last?.id) { _, newest in
            // Hide the new segment in this same update, before it draws.
            guard let newest else { shownThrough = -1; return }
            shownThrough = newest - 1
            revealed = (newest, 0)
        }
        .task(id: segments.last?.id) { await reveal() }
    }

    private struct Block { let x: CGFloat; let width: CGFloat; let opacity: Double }

    private func layout(width available: CGFloat) -> [[Block]] {
        // Only the tail can be on screen; cap the work for long sessions.
        var budget = 600
        var tail: [CapturedSegment] = []
        for seg in segments.reversed() where budget > 0 {
            tail.append(seg)
            budget -= seg.blockCount
        }
        tail.reverse()

        var lines: [[Block]] = [[]]
        var x: CGFloat = 0
        for (offset, seg) in tail.enumerated() {
            let age = tail.count - 1 - offset
            let opacity = age == 0 ? 0.72 : age == 1 ? 0.5 : age <= 3 ? 0.32 : 0.2
            var count = seg.blockCount
            if seg.id > shownThrough {
                count = revealed?.id == seg.id ? min(count, revealed?.count ?? 0) : 0
            }
            for w in 0..<count {
                let blockWidth = min(Self.blockWidth(segment: seg.id, word: w), available)
                if x > 0, x + blockWidth > available {
                    lines.append([])
                    x = 0
                }
                lines[lines.count - 1].append(Block(x: x, width: blockWidth, opacity: opacity))
                x += blockWidth + Self.wordGap
            }
        }
        return lines
    }

    private func reveal() async {
        guard let newest = segments.last, newest.id > shownThrough else { return }
        if !reduceMotion, newest.blockCount > 1 {
            let step = min(0.14, 2.0 / Double(newest.blockCount))
            for n in 1...newest.blockCount {
                revealed = (newest.id, n)
                try? await Task.sleep(for: .seconds(step))
                if Task.isCancelled { return }
            }
        }
        shownThrough = newest.id
        revealed = nil
    }

    /// Deterministic 14...60 pt width per word position.
    private static func blockWidth(segment: Int, word: Int) -> CGFloat {
        var h = UInt64(truncatingIfNeeded: segment) &* 0x9E3779B97F4A7C15 &+ UInt64(word) &* 0xBF58476D1CE4E5B9
        h ^= h >> 31
        return 14 + CGFloat(h % 47)
    }
}
