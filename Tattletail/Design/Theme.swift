import SwiftUI

/// Tattletail's warm-minimalist design language.
///
/// Palette: soft cream/paper surfaces, terracotta accent, amber highlights,
/// warm neutral grays. Rounded type, generous spacing, subtle depth.
enum Theme {
    // MARK: Colors (light / dark aware)

    /// Primary accent — terracotta.
    static let accent = Color(light: Color(red: 0.80, green: 0.42, blue: 0.31),
                              dark: Color(red: 0.88, green: 0.52, blue: 0.40))

    /// Secondary accent — warm amber, used for recording/live states.
    static let amber = Color(light: Color(red: 0.90, green: 0.62, blue: 0.26),
                             dark: Color(red: 0.95, green: 0.70, blue: 0.36))

    /// Success / confirmation — warm sage.
    static let sage = Color(light: Color(red: 0.48, green: 0.60, blue: 0.42),
                            dark: Color(red: 0.58, green: 0.70, blue: 0.52))

    /// Destructive / stop — warm brick red. (Already clears 4.5:1 with white.)
    static let brick = Color(light: Color(red: 0.76, green: 0.28, blue: 0.22),
                             dark: Color(red: 0.86, green: 0.40, blue: 0.34))

    // MARK: Filled-button fills (white text ≥ 4.5:1, WCAG AA)
    //
    // The vivid accents above stay bright for icon tints and the activity glow,
    // where they sit on light surfaces or convey state alongside a text label.
    // Filled buttons draw white text, so they use these deeper shades of the same
    // warm hues — dark enough for AA in both light and dark appearance, and still
    // clearly raised against the near-black dark-mode background.

    /// Terracotta fill for primary filled buttons.
    static let accentButton = Color(red: 0.70, green: 0.34, blue: 0.25)
    /// Amber/ochre fill for amber filled buttons.
    static let amberButton = Color(red: 0.66, green: 0.40, blue: 0.08)
    /// Sage fill for sage filled buttons.
    static let sageButton = Color(red: 0.36, green: 0.49, blue: 0.32)
    /// Deep brick fill for destructive/stop filled buttons — white text ≈ 6:1 in
    /// both appearances (the bright `brick` accent fails AA with white in dark).
    static let brickButton = Color(red: 0.68, green: 0.24, blue: 0.19)

    /// Window background — cream paper.
    static let background = Color(light: Color(red: 0.98, green: 0.96, blue: 0.93),
                                  dark: Color(red: 0.13, green: 0.12, blue: 0.11))

    /// Raised card surface.
    static let surface = Color(light: .white,
                               dark: Color(red: 0.18, green: 0.17, blue: 0.16))

    /// Subtle inset surface (wells, timelines).
    static let inset = Color(light: Color(red: 0.955, green: 0.935, blue: 0.90),
                             dark: Color(red: 0.155, green: 0.145, blue: 0.135))

    /// Primary text — warm near-black.
    static let ink = Color(light: Color(red: 0.22, green: 0.19, blue: 0.17),
                           dark: Color(red: 0.93, green: 0.91, blue: 0.88))

    /// Secondary text — warm gray.
    static let inkSecondary = Color(light: Color(red: 0.50, green: 0.46, blue: 0.42),
                                    dark: Color(red: 0.65, green: 0.62, blue: 0.58))

    /// Hairline borders.
    static let border = Color(light: Color(red: 0.88, green: 0.85, blue: 0.81),
                              dark: Color(red: 0.27, green: 0.25, blue: 0.23))

    /// Card drop shadow — a heavier cast in dark mode so it stays visible against
    /// the near-black background (a faint black shadow vanishes there).
    static let cardShadow = Color(light: .black.opacity(0.06),
                                  dark: .black.opacity(0.35))

    // MARK: Metrics

    static let cornerRadius: CGFloat = 10
    static let cardCornerRadius: CGFloat = 14
    static let spacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 20

    // MARK: Type

    /// Global text scale. All Theme fonts are multiplied by this, so the whole
    /// app's type can be sized from one place.
    static let textScale: CGFloat = 1.25

    static func title(_ size: CGFloat = 22) -> Font {
        .system(size: size * textScale, weight: .semibold, design: .rounded)
    }

    static func body(_ size: CGFloat = 13) -> Font {
        .system(size: size * textScale, weight: .regular, design: .rounded)
    }

    static func label(_ size: CGFloat = 12) -> Font {
        .system(size: size * textScale, weight: .medium, design: .rounded)
    }

    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size * textScale, weight: .regular, design: .monospaced)
    }
}

extension Color {
    /// A color that adapts between light and dark appearances.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - Reusable styling

/// A soft raised card.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Theme.cardShadow, radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Rounded, filled accent button (primary actions).
struct WarmButtonStyle: ButtonStyle {
    var color: Color = Theme.accentButton

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.75 : 1))
            )
    }
}

/// Quiet bordered button (secondary actions).
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.inset.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}
