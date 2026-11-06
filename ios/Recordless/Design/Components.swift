import SwiftUI

// MARK: - Buttons

/// Primary button: `primary` fill, radius 14, 17 pt bold. Height 54, or 50 in
/// bottom bars.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = Theme.Spacing.primaryButton
    var fontSize: CGFloat = Theme.Size.body

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, height: height, fontSize: fontSize)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.font(fontSize, .bold))
                .foregroundStyle(Theme.primaryForeground)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(Theme.primary, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// Secondary button: same size, `card` fill, 1 pt `border`, `foreground` text.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = Theme.Spacing.primaryButton
    var fontSize: CGFloat = Theme.Size.body

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
        return configuration.label
            .font(Theme.font(fontSize, .bold))
            .foregroundStyle(Theme.foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(configuration.isPressed ? Theme.muted : Theme.card, in: shape)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Text-only button (links such as "All notes", "Discard session").
struct TextButtonStyle: ButtonStyle {
    var color: Color = Theme.primary
    var size: CGFloat = Theme.Size.row

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(size, .semibold))
            .foregroundStyle(color)
            .frame(minHeight: Theme.Spacing.minTouch)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var height: CGFloat = Theme.Spacing.primaryButton
    let action: () -> Void

    var body: some View {
        Button(action: action) { ButtonLabel(title: title, systemImage: systemImage) }
            .buttonStyle(PrimaryButtonStyle(height: height, fontSize: height < Theme.Spacing.primaryButton ? Theme.Size.row : Theme.Size.body))
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var height: CGFloat = Theme.Spacing.primaryButton
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ButtonLabel(title: title, systemImage: systemImage, iconColor: Theme.primary)
        }
        .buttonStyle(SecondaryButtonStyle(height: height, fontSize: height < Theme.Spacing.primaryButton ? Theme.Size.row : Theme.Size.body))
    }
}

private struct ButtonLabel: View {
    let title: String
    let systemImage: String?
    var iconColor: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                    .accessibilityHidden(true)
            }
            Text(title)
        }
    }
}

/// Round outline icon button (lock, pause). Needs an accessibility label.
struct CircleIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = Theme.Spacing.minTouch
    var iconSize: CGFloat = 17
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: size, height: size)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Labels, pills, tags

/// 12 pt bold uppercase, 0.06 em tracking, `mutedForeground`.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.font(Theme.Size.sectionLabel, .bold, relativeTo: .caption))
            .tracking(Theme.Size.sectionLabel * 0.06)
            .foregroundStyle(Theme.mutedForeground)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Chip: height 36, padding 12, full radius, 1 pt `border`, 14 pt. Used for
/// pickers (mic, language) and quick-add chips.
struct Pill<Leading: View>: View {
    let title: String
    var selected = false
    var showsChevron = false
    var fill: Color = Theme.background
    var textColor: Color = Theme.foreground
    var weight: Theme.Weight = .regular
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 6) {
            leading()
            Text(title)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
                    .accessibilityHidden(true)
            }
        }
        .font(Theme.font(Theme.Size.secondary, weight))
        .foregroundStyle(textColor)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(selected ? Theme.primarySoft : fill, in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? Theme.primaryBorder : Theme.border, lineWidth: 1))
        .contentShape(Capsule())
    }
}

extension Pill where Leading == EmptyView {
    init(title: String, selected: Bool = false, showsChevron: Bool = false,
         fill: Color = Theme.background, textColor: Color = Theme.foreground, weight: Theme.Weight = .regular) {
        self.init(title: title, selected: selected, showsChevron: showsChevron,
                  fill: fill, textColor: textColor, weight: weight) { EmptyView() }
    }
}

/// Small status tag (Draft, Notes ready, Session ended).
struct StatusTag: View {
    enum Kind { case draft, ready, ended, neutral, queued }
    let text: String
    let kind: Kind
    var systemImage: String?
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 9 : 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(Theme.font(compact ? Theme.Size.sectionLabel : Theme.Size.meta,
                         kind == .neutral || kind == .ready ? .semibold : .bold, relativeTo: .caption))
        .foregroundStyle(colors.text)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 2 : 3)
        .background(colors.fill, in: Capsule())
    }

    private var colors: (fill: Color, text: Color) {
        switch kind {
        case .draft: (Theme.infoSoft, Theme.primary)
        case .ready, .ended: (Theme.successSoft, Theme.success)
        case .neutral: (Theme.secondary, Theme.foreground)
        case .queued: (Theme.secondary, Theme.mutedForeground)
        }
    }
}

/// "In memory only — …" line with the chip icon.
struct InMemoryLine: View {
    let rest: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "cpu")
                .font(.system(size: 12))
                .foregroundStyle(Theme.foreground)
                .accessibilityHidden(true)
            let lead = Text("In memory only")
                .font(Theme.font(Theme.Size.meta, .bold, relativeTo: .footnote))
                .foregroundStyle(Theme.foreground)
            Text("\(lead) — \(rest)")
                .font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                .foregroundStyle(Theme.mutedForeground)
        }
    }
}

// MARK: - Progress, toggles, level bar

/// Small determinate-looking spinner ring used for "Writing notes…".
struct ProgressRing: View {
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Angle from the clock, so no implicit animation leaks into layout
        // changes (pushes, list updates). Static under Reduce Motion.
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turns = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle().stroke(Theme.infoSoft, lineWidth: 3)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Theme.info, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(turns * 360))
            }
        }
        .frame(width: size - 3, height: size - 3)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Card row with a title, subtitle and a switch.
struct ToggleCard: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(Theme.Size.row, .semibold))
                    .foregroundStyle(Theme.foreground)
                Text(subtitle).font(Theme.font(Theme.Size.meta, relativeTo: .footnote))
                    .foregroundStyle(Theme.mutedForeground)
            }
        }
        .tint(Theme.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardStyle(shadow: false)
    }
}

/// Selectable radio card (Generate notes: where to write).
struct RadioCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.primary : Theme.mutedForeground)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.font(Theme.Size.row, .bold))
                        .foregroundStyle(Theme.foreground)
                    Text(detail).font(Theme.font(Theme.Size.secondary))
                        .foregroundStyle(Theme.mutedForeground)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(selected ? Theme.primarySoft : Theme.card, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.primary : Theme.border, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 16-segment mic level bar. Zones: 1–12 good, 13–14 warm, 15–16 hot.
/// Never red.
struct SegmentedLevelBar: View {
    /// 0...1 from smoothed RMS.
    let level: Double
    static let segments = 16

    static func lit(for level: Double) -> Int {
        Int((min(max(level, 0), 1) * Double(segments)).rounded())
    }

    var body: some View {
        let lit = Self.lit(for: level)
        HStack(spacing: 3) {
            ForEach(0..<Self.segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: Theme.Radius.segment, style: .continuous)
                    .fill(i < lit ? Self.zone(i).lit : Self.zone(i).unlit)
                    .frame(height: 10)
            }
        }
        .accessibilityHidden(true)
    }

    private static func zone(_ i: Int) -> (lit: Color, unlit: Color) {
        switch i {
        case ..<12: (Theme.success, Theme.successSoft)
        case ..<14: (Theme.meterAmber, Theme.meterAmberSoft)
        default: (Theme.meterOrange, Theme.meterOrangeSoft)
        }
    }
}

// MARK: - Sheets

/// Shared sheet chrome: background, corner radius, and a height that fits
/// the content.
private struct FittedSheet: ViewModifier {
    @State private var height: CGFloat = 500

    func body(content: Content) -> some View {
        // Scrolls only when the content (large Dynamic Type) is taller than
        // the screen; otherwise the sheet is exactly as tall as the content.
        ScrollView {
            content
                .padding(.horizontal, Theme.Spacing.screenSide)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(height)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Theme.Radius.sheet)
            .presentationBackground(Theme.background)
    }
}

extension View {
    func fittedSheet() -> some View { modifier(FittedSheet()) }
}

// MARK: - Touch target

extension View {
    /// Keeps a smaller look (36 pt chips) with a 44 pt tap area.
    func touchTarget() -> some View {
        frame(minWidth: Theme.Spacing.minTouch, minHeight: Theme.Spacing.minTouch)
            .contentShape(Rectangle())
    }
}

// MARK: - Logo

struct LogoView: View {
    var size: CGFloat

    var body: some View {
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Recordless")
    }
}
