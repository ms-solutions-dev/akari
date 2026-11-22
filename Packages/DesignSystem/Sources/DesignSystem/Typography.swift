import CoreText
import Foundation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The typography: Newsreader (serif, variable, OFL) for titles
/// and names, the system grotesque for text, fixed digit width everywhere numbers
/// stand in columns. All relative to a text style so Dynamic Type grows
/// along up to AX3.
///
/// **The typeface lives in the package, not in the app** (`Schriften/Newsreader.ttf`) and
/// is registered on first access - so a preview in a
/// package that has no app at all knows it too. If the file is missing, everything falls back to the system serif,
/// and the test `TypographyTests` says so.
public enum Typography {

    public static let serifName = "Newsreader"

    /// Whether Newsreader could be loaded - computed once, then remembered.
    public static let serifAvailable: Bool = {
        guard
            let url = Bundle.module.url(
                forResource: "Newsreader", withExtension: "ttf", subdirectory: "Schriften")
        else { return false }
        var failure: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &failure) { return true }
        // Already registered (second call in the same session) counts as success.
        if let code = failure?.takeRetainedValue(),
            CFErrorGetCode(code) == CTFontManagerError.alreadyRegistered.rawValue
        {
            return true
        }
        return false
    }()

    /// Page title, series name, book title - the serif, semibold.
    public static func title(_ style: Font.TextStyle = .title, weight: Font.Weight = .medium) -> Font {
        serif(style, weight: weight)
    }

    /// The name in tile and row: serif, medium, in the size of the text style.
    public static func name(_ style: Font.TextStyle = .subheadline) -> Font {
        serif(style, weight: .medium)
    }

    /// The index in a row ("13") and the digits of the progress - system grotesque
    /// with fixed digit width comes via `.monospacedDigit()` on the text.
    public static func text(_ style: Font.TextStyle = .body) -> Font {
        .system(style)
    }

    /// The badge: grotesque, small, letter-spaced (`.tracking(1.2)` on the text).
    public static let badge: Font = .system(.caption2, weight: .semibold)

    private static func serif(_ style: Font.TextStyle, weight: Font.Weight) -> Font {
        if serifAvailable {
            return .custom(postScriptName(weight), size: Self.size(style), relativeTo: style)
        }
        return .system(style, design: .serif, weight: weight)
    }

    /// The cuts of the variable file are called `NewsreaderRoman-Medium` etc. -
    /// `.weight()` does not take on a `custom` font, the name does.
    static func postScriptName(_ weight: Font.Weight) -> String {
        switch weight {
        case .semibold: "NewsreaderRoman-SemiBold"
        case .bold, .heavy, .black: "NewsreaderRoman-Bold"
        case .light, .thin, .ultraLight: "NewsreaderRoman-Light"
        case .regular: "Newsreader16pt-Regular"
        default: "NewsreaderRoman-Medium"
        }
    }

    /// The titles of the navigation bar in serif - once at start, for all
    /// stacks. SwiftUI has no modifier for it; UIKit's appearance is the way.
    /// On the Mac it does nothing.
    @MainActor
    public static func shapeNavigationBar() {
        #if canImport(UIKit) && !os(tvOS)
            guard serifAvailable, let large = UIFont(name: postScriptName(.medium), size: 34),
                let small = UIFont(name: postScriptName(.medium), size: 17)
            else { return }
            let metrics = UIFontMetrics(forTextStyle: .largeTitle)
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.largeTitleTextAttributes = [.font: metrics.scaledFont(for: large)]
            appearance.titleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: small)
            ]
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        #endif
    }

    /// The base sizes of the text styles (iOS, Large) - Newsreader needs them, because
    /// `.custom` wants a number and only `relativeTo` brings the scaling.
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}
