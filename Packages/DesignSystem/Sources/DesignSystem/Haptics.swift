import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Haptics, sparingly: selection in the segment, success after signing in, warning on
/// a rejection. Nothing when paging - in the reader every page would tap.
/// On the Mac (preview, `swift test`) it does nothing.
public enum Haptics {

    @MainActor
    public static func selection() {
        #if canImport(UIKit) && !os(tvOS)
            UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    @MainActor
    public static func success() {
        #if canImport(UIKit) && !os(tvOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    @MainActor
    public static func warning() {
        #if canImport(UIKit) && !os(tvOS)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}

/// Motion that respects "Reduce Motion": whoever has it on gets the
/// change without travel - not slower, but immediate.
public enum Motion {

    /// The short motion for selection and toggling.
    public static func short(_ calm: Bool) -> Animation? {
        calm ? nil : .easeOut(duration: 0.18)
    }

    /// The soft one for fading rows and banners in and out.
    public static func soft(_ calm: Bool) -> Animation? {
        calm ? nil : .easeInOut(duration: 0.28)
    }

    // MARK: - Springs

    /// Toggle, segment, grid <-> rows.
    public static func fast(_ calm: Bool) -> Animation? {
        calm ? nil : .spring(response: 0.30, dampingFraction: 0.90)
    }

    /// Own sheets and cards.
    public static func sheet(_ calm: Bool) -> Animation? {
        calm ? nil : .spring(response: 0.42, dampingFraction: 0.88)
    }

    /// Cover -> detail -> reader, mini -> full player. With "Reduce Motion" a short
    /// cross-fade instead of nothing (zoom becomes a 0.2 s fade).
    public static func zoom(_ calm: Bool) -> Animation {
        calm ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)
    }

    /// Saved ribbon, success - overshoots once; calm without overshoot.
    public static func bounce(_ calm: Bool) -> Animation {
        calm ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.62)
    }

    /// **Only in the reader**: bars fade in and out.
    public static func calm(_ calm: Bool) -> Animation? {
        calm ? nil : .easeInOut(duration: 0.22)
    }
}

/// The radii: larger than before, because iOS 26 glass,
/// sheets and lists round noticeably. The capsule stays reserved for glass.
public enum Radius {
    public static let cover: CGFloat = 4
    public static let hero: CGFloat = 6
    public static let chip: CGFloat = 10
    public static let button: CGFloat = 14
    public static let card: CGFloat = 20
}

/// The minimum tap target of the HIG, as a number in one place.
public enum TapTarget {
    public static let atLeast: CGFloat = 44
}
