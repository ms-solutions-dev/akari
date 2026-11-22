import SwiftUI

/// A content that needs the downward drag itself locks the close gesture above it - the
/// book reader in flowing mode, where the same drag scrolls the text.
public struct CloseGestureLocked: PreferenceKey {
    public static let defaultValue = false
    public static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
