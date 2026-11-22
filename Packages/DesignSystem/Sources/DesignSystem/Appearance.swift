import SwiftUI

/// Light, dark - or as the system.
///
/// The app follows the system; whoever wants otherwise switches it here.
/// The four color themes come alongside, not instead: a theme is an
/// accent and paper pair for light and dark, and this choice says which half applies.
public enum Appearance: String, CaseIterable, Sendable, Identifiable {
    case system, light = "hell", dark = "dunkel"

    /// Where the choice lives - a storage key, not a language key.
    public static let storeKey = "app.appearance"

    public var id: String { rawValue }

    /// The language key for the row in the picker.
    public var lookupKey: String { "appearance." + rawValue }

    /// What goes to the root - `nil` means: the system decides.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
