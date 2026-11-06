import SwiftUI

/// Design tokens from `docs/design/tokens.json`. This is the only file that
/// holds raw color values; views use the token names.
enum Theme {
    // MARK: Colors

    static let background = Color(hex: 0xFBFAF7)
    static let foreground = Color(hex: 0x111827)
    static let card = Color(hex: 0xFFFFFF)
    static let primary = Color(hex: 0x283962)
    static let primaryForeground = Color(hex: 0xFCFBF8)
    static let primarySoft = Color(hex: 0xEBF0F8)
    static let primaryBorder = Color(hex: 0xD7DFEC)
    static let secondary = Color(hex: 0xF4F1EB)
    static let muted = Color(hex: 0xF5F3EF)
    static let mutedForeground = Color(hex: 0x6C6660)
    static let accent = Color(hex: 0xF2EADE)
    static let border = Color(hex: 0xE4DFD8)
    static let info = Color(hex: 0x3B589B)
    static let infoSoft = Color(hex: 0xEAEFF8)
    static let success = Color(hex: 0x2F8A62)
    static let successSoft = Color(hex: 0xE9F4EE)
    static let warning = Color(hex: 0x935610)
    static let warningSoft = Color(hex: 0xFBF4E7)
    /// Errors and delete. Never use red for live or error states.
    static let destructive = Color(hex: 0xA8413A)
    /// The logo's red. Logo only.
    static let brandDot = Color(hex: 0xE5362F)
    static let logoNavy = Color(hex: 0x223868)
    static let reviewTitle = Color(hex: 0x1A2C52)
    static let reviewBody = Color(hex: 0x33415C)
    static let sheetBackdrop = Color(hex: 0x4A4F5C)
    static let meterAmber = Color(hex: 0xDC9418)
    static let meterAmberSoft = Color(hex: 0xFBF4E7)
    static let meterOrange = Color(hex: 0xE56106)
    static let meterOrangeSoft = Color(hex: 0xFCE9DC)
    static let meterHotText = Color(hex: 0xA84A0A)

    // MARK: Type

    enum Weight { case regular, semibold, bold }

    enum Size {
        static let timer: CGFloat = 56
        static let largeTitle: CGFloat = 32
        static let noteTitle: CGFloat = 30
        static let sheetTitle: CGFloat = 26
        static let body: CGFloat = 17
        static let row: CGFloat = 16
        static let control: CGFloat = 15
        static let secondary: CGFloat = 14
        static let meta: CGFloat = 13
        static let sectionLabel: CGFloat = 12
        static let tab: CGFloat = 11
    }

    /// Source Sans 3 at a design size, scaled with Dynamic Type relative to
    /// `textStyle`.
    static func font(_ size: CGFloat, _ weight: Weight = .regular,
                     relativeTo textStyle: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .regular: "SourceSans3-Regular"
        case .semibold: "SourceSans3-SemiBold"
        case .bold: "SourceSans3-Bold"
        }
        return .custom(name, size: size, relativeTo: textStyle)
    }

    /// Instrument Serif, for the wordmark only.
    static func wordmark(_ size: CGFloat) -> Font {
        .custom("InstrumentSerif-Regular", size: size, relativeTo: .largeTitle)
    }

    // MARK: Shape and spacing

    enum Radius {
        static let segment: CGFloat = 2
        static let block: CGFloat = 3
        static let input: CGFloat = 12
        static let button: CGFloat = 14
        static let card: CGFloat = 14
        static let largeCard: CGFloat = 16
        static let sheet: CGFloat = 22
    }

    enum Spacing {
        static let screenSide: CGFloat = 20
        /// Below the status bar (the design's 62 pt minus the status bar).
        static let topInset: CGFloat = 8
        static let stackGap: CGFloat = 16
        static let rowHeight: CGFloat = 60
        static let minTouch: CGFloat = 44
        static let primaryButton: CGFloat = 54
        static let barButton: CGFloat = 50
    }
}

extension Color {
    /// Only for `Theme`; views use token names.
    fileprivate init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Card: `card` fill, 1 pt `border`, radius 14 (16 for large), 5% shadow.
    func cardStyle(radius: CGFloat = Theme.Radius.card, shadow: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: Theme.foreground.opacity(shadow ? 0.05 : 0), radius: 1, y: 1)
    }

    /// Screen background that runs under the bars.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
