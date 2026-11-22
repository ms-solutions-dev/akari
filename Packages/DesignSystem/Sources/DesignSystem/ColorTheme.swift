import SwiftUI

/// The four color themes: ink (default), terracotta, indigo,
/// plum. A theme changes exactly two things - the accent and the paper tone, with
/// the surfaces and hairlines that hang on them. Serifs, ink, spacing and covers
/// stay; the comic reader stays black in every theme.
///
/// The values are the ones from the design reference (WCAG computed): accent on
/// paper >= 4.5 : 1, ink on paper >= 7 : 1 - `ColorThemeTests` recomputes this so
/// a changed value does not silently fall below it.
public enum ColorTheme: String, CaseIterable, Sendable, Identifiable, Codable {
    case ink = "tinte", terracotta = "terrakotta", indigo, plum = "pflaume"

    public static let preset: ColorTheme = .ink

    public var id: String { rawValue }

    /// The language key for the name in the picker.
    public var lookupKey: String { "theme." + rawValue }

    // MARK: - The two values per theme

    /// Buttons, links, segment selection, badges, progress, tab underline.
    public var accent: AdaptiveColor {
        switch self {
        case .ink: AdaptiveColor(light: 0x1F5C46, dark: 0x8FC7AE)
        case .terracotta: AdaptiveColor(light: 0xA9482B, dark: 0xF0A585)
        case .indigo: AdaptiveColor(light: 0x2E4A8C, dark: 0x9DB8F0)
        case .plum: AdaptiveColor(light: 0x6B2F5C, dark: 0xD9A3CC)
        }
    }

    /// The ground - background of every page and every sheet.
    public var paper: AdaptiveColor {
        switch self {
        case .ink: AdaptiveColor(light: 0xFAFAF8, dark: 0x1A1B1A)
        case .terracotta: AdaptiveColor(light: 0xFBF7F2, dark: 0x1E1917)
        case .indigo: AdaptiveColor(light: 0xF7F8FB, dark: 0x171A22)
        case .plum: AdaptiveColor(light: 0xFBF6F9, dark: 0x1E171C)
        }
    }

    // MARK: - What hangs on the paper

    /// The slightly tinted surface: segment background, search field, cover placeholder.
    public var surface: AdaptiveColor {
        switch self {
        case .ink: AdaptiveColor(light: 0xF1EFE8, dark: 0x262624)
        case .terracotta: AdaptiveColor(light: 0xF2ECE4, dark: 0x2A2320)
        case .indigo: AdaptiveColor(light: 0xECEEF4, dark: 0x22262F)
        case .plum: AdaptiveColor(light: 0xF2EAF0, dark: 0x2A2127)
        }
    }

    /// Hairlines: dividers, borders around row index and genre card.
    public var hairline: AdaptiveColor {
        switch self {
        case .ink: AdaptiveColor(light: 0xDAD6CD, dark: 0x343330)
        case .terracotta: AdaptiveColor(light: 0xE2D9CE, dark: 0x3A312C)
        case .indigo: AdaptiveColor(light: 0xD8DCE6, dark: 0x31363F)
        case .plum: AdaptiveColor(light: 0xE3D6DF, dark: 0x3A2F36)
        }
    }

    /// Raised surfaces in the dark (card, banner); in the light the paper itself.
    public var fill: AdaptiveColor {
        switch self {
        case .ink: AdaptiveColor(light: 0xFAFAF8, dark: 0x2E2D2B)
        case .terracotta: AdaptiveColor(light: 0xFBF7F2, dark: 0x332A26)
        case .indigo: AdaptiveColor(light: 0xF7F8FB, dark: 0x2A2E38)
        case .plum: AdaptiveColor(light: 0xFBF6F9, dark: 0x332830)
        }
    }

    /// Elevated surfaces (levels 1-2): cards, sheets, person card. In light
    /// white over the paper, in dark the surface with about 3 % more light.
    public var raised: AdaptiveColor {
        switch self {
        case .ink: AdaptiveColor(light: 0xFFFFFF, dark: 0x2E2E2C)
        case .terracotta: AdaptiveColor(light: 0xFFFFFF, dark: 0x322B28)
        case .indigo: AdaptiveColor(light: 0xFFFFFF, dark: 0x2A2E37)
        case .plum: AdaptiveColor(light: 0xFFFFFF, dark: 0x322930)
        }
    }

    // MARK: - What no theme changes

    /// The typography: ink on paper - `typography`, because `ink` is already the theme's name.
    public static let typography = AdaptiveColor(light: 0x1B1A17, dark: 0xECEAE4)
    /// Secondary text: author, metadata, state word.
    public static let muted = AdaptiveColor(light: 0x6D6A62, dark: 0xA19E96)
    /// A line with meaning (track of a progress bar, border of an input field),
    /// >= 3 : 1 - `line` is deliberately decoration at 1.4 : 1.
    public static let track = AdaptiveColor(light: 0x8C877C, dark: 0x6E6B64)

    // MARK: - Signal colors

    /// Error: sign-in expired, server gone, delete. Against paper 6.3 : 1 / 7.6 : 1 -
    /// the old `.red` had 3.4 : 1.
    public static let failure = AdaptiveColor(light: 0xB3261E, dark: 0xFF8A80)
    /// Warning: slow connection, storage low. 6.1 : 1 / 10.3 : 1.
    public static let warning = AdaptiveColor(light: 0x8A5300, dark: 0xF2C063)
    /// OK: connected, loaded, synchronized. 6.2 : 1 / 9.5 : 1.
    public static let ok = AdaptiveColor(light: 0x1E6B45, dark: 0x7FD1A0)

    /// The level of a message - comparable, unlike a dynamic `Color`.
    public enum Signal: Sendable, Equatable {
        case failure, warning, ok

        public var adaptive: AdaptiveColor {
            switch self {
            case .failure: ColorTheme.failure
            case .warning: ColorTheme.warning
            case .ok: ColorTheme.ok
            }
        }

        public var color: Color { adaptive.color }
    }

    /// The comic reader - in every theme, in every brightness.
    public static let readerBlack = AdaptiveColor(0x000000)

    /// Button text on accent: white in light, paper in dark.
    public var buttonText: AdaptiveColor {
        AdaptiveColor(light: 0xFFFFFF, dark: paper.dark)
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: ColorTheme = .preset
}

extension EnvironmentValues {
    /// The chosen theme - set at the root, read everywhere. No building block
    /// writes a color in; it asks here.
    public var theme: ColorTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Sets the theme at the root: environment, `tint` and paper behind everything.
    public func theme(_ theme: ColorTheme) -> some View {
        self.environment(\.theme, theme)
            .tint(theme.accent.color)
            .background(theme.paper.color.ignoresSafeArea())
    }

    /// Paper behind a list or a form: the system grouping otherwise paints
    /// its own gray or black over it - in the dark the theme fell
    /// out of the picture.
    public func paper() -> some View {
        modifier(Paper())
    }
}

private struct Paper: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(theme.paper.color.ignoresSafeArea())
    }
}
