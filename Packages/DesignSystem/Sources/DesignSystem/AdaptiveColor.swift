import SwiftUI
import Synchronization

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A color value from the design: a hex pair for light and dark, measured in the
/// design reference and held here as a number - so a test can compute the contrast
/// without asking SwiftUI.
public struct AdaptiveColor: Sendable, Hashable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    /// The same color in light and dark - the reader blacks, white on buttons.
    public init(_ both: UInt32) {
        self.init(light: both, dark: both)
    }

    /// The SwiftUI color that follows the appearance - including one the user
    /// forced: the environment carries it as a trait, and the provider asks exactly that.
    ///
    /// **Created once per value**: a dynamic color with its own
    /// provider closure is not equal to any other, not even one from the same hex pair -
    /// SwiftUI saw each of the 200-odd color uses as changed on every pass and
    /// redrew them, in the player on every frame of the drag.
    public var color: Color {
        if let saved = AdaptiveColor.saved.withLock({ $0[self] }) { return saved }
        let new = built
        AdaptiveColor.saved.withLock { $0[self] = new }
        return new
    }

    private static let saved = Mutex<[AdaptiveColor: Color]>([:])

    private var built: Color {
        #if canImport(UIKit)
            return Color(
                uiColor: UIColor { traits in
                    Self.uiColor(traits.userInterfaceStyle == .dark ? dark : light)
                })
        #elseif canImport(AppKit)
            return Color(
                nsColor: NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return Self.nsColor(dark ? self.dark : light)
                })
        #else
            return Color(hex: light)
        #endif
    }

    /// Relative luminance per WCAG 2.x - for the contrast calculation in tests.
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722
            * channel(hex & 0xFF)
    }

    /// Contrast of two colors per WCAG: (L1 + 0.05) / (L2 + 0.05), light over dark.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func rgbComponents(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    #if canImport(UIKit)
        private static func uiColor(_ hex: UInt32) -> UIColor {
            let (r, g, b) = rgbComponents(hex)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
    #elseif canImport(AppKit)
        private static func nsColor(_ hex: UInt32) -> NSColor {
            let (r, g, b) = rgbComponents(hex)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    #endif
}

extension Color {
    /// A fixed color from a hex value - for what never changes with a theme.
    public init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
