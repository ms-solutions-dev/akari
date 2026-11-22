import SwiftUI
import UIKit

/// The design language reproduced to the bare minimum: the six colors of the theme
/// "Ink" in light and dark and the serif for names.
///
/// **Why reproduced and not pulling in `DesignSystem`:** the package brings the
/// Newsreader file, Bedrock, the worm and the building blocks along - for a widget
/// that draws a bar and two lines that would be a second app build in the
/// extension process with its 30 MB cap. The values here are the ones from
/// `ColorTheme.ink` (`Packages/DesignSystem/Sources/DesignSystem/ColorTheme.swift`); whoever changes them
/// there changes them here too. The widget does not know the profile's chosen theme
/// - it stays at the default, as the app icon does.
///
/// **The serif is the system's (New York), not Newsreader:** the font file
/// lies in the DesignSystem package and is registered there on first access;
/// putting it into the widget a second time would mean shipping 300 KB twice. The
/// system serif is the nearest relative, and the widget is small enough that
/// the difference is not noticeable.
enum WidgetLook {

    static let paper = color(light: 0xFAFA_F8, dark: 0x1A1B_1A)
    static let accent = color(light: 0x1F5C_46, dark: 0x8FC7_AE)
    static let typography = color(light: 0x1B1A_17, dark: 0xECEA_E4)
    static let muted = color(light: 0x6D6A_62, dark: 0xA19E_96)
    static let surface = color(light: 0xF1EF_E8, dark: 0x2626_24)
    static let hairline = color(light: 0xDAD6_CD, dark: 0x3433_30)

    /// The three kinds in the week strip of the reading-time widget: book in the accent
    /// of the theme, manga and audiobook in the accents of the sister themes terracotta
    /// and indigo - the same table the app keeps for its four themes, nothing
    /// foreign. Computed against paper like the accents themselves (>= 4.5 : 1).
    static let book = accent
    static let manga = color(light: 0xA948_2B, dark: 0xF0A5_85)
    static let audiobook = color(light: 0x2E4A_8C, dark: 0x9DB8_F0)

    /// Name of a title - serif, semibold, in the size of the text style.
    static func name(_ style: Font.TextStyle) -> Font {
        .system(style, design: .serif, weight: .medium)
    }

    /// The badge above the name: grotesque, small, letter-spaced.
    static let badge: Font = .system(.caption2, weight: .semibold)

    /// A large number - serif, like the figures in the statistics sheet.
    static let figure: Font = .system(.title, design: .serif, weight: .semibold)

    /// "2 h 15 min", "35 min", "3 h" - terse, as the app says it in the statistics sheet;
    /// the templates come from the extension's catalog.
    static func time(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60, minutes % 60 == 0 { return Phrase.from("widget.time.onlyH", minutes / 60) }
        return minutes >= 60
            ? Phrase.from("widget.time.h", minutes / 60, minutes % 60)
            : Phrase.from("widget.time.min", minutes)
    }

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(
            uiColor: UIColor { track in
                track.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
            })
    }
}

/// A sentence from the extension's catalog with values - the same form as in `Features`.
enum Phrase {
    static func from(_ lookupKey: String, _ values: CVarArg...) -> String {
        let template = String(localized: String.LocalizationValue(lookupKey), bundle: .main)
        return String(format: template, locale: .current, arguments: values)
    }
}

extension UIColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
