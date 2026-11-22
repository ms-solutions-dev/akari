import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// What this device should be called in the household's device list.
///
/// **The name is the only thing the app contributes.** Where a device comes from
/// is stated by the server itself. There is no origin field in the body, because
/// the origin is the address of the request, and an app cannot state it without
/// also being able to state it falsely. What remains are the device kind and this
/// name.
///
/// **And it has a job:** in a list of nothing but "Browser" (what the server
/// calls a device without a name) none is recognizable, and signing out becomes
/// guesswork. Anyone who wants to remove a foreign device from their household
/// must be able to tell it apart.
///
/// **`UIDevice.current.name` has not been a device name on iOS since 16**, but the
/// model ("iPhone"), unless the app holds a special entitlement. On tvOS it is
/// still the name the owner set ("Living Room"). Both are usable: the television
/// is named after its room, the phone after its model, and for the latter the
/// person's name is added at sign-in anyway.
public enum DeviceName {

    /// The name of this device.
    ///
    /// **`@MainActor`, because `UIDevice.current` is.** It is read when pairing and
    /// when signing in, and both happen in a view, where the binding costs nothing.
    /// An `assumeIsolated` would only have hidden the same warning.
    @MainActor
    public static var thisDevice: String {
        #if canImport(UIKit)
            let reported = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reported.isEmpty { return reported }
        #endif
        return fallback
    }

    /// When the system provides nothing.
    ///
    /// **By platform and not "device".** A household has one television and several
    /// phones; "device" does not separate them, "Apple TV" and "iPhone" do.
    private static var fallback: String {
        #if os(tvOS)
            "Apple TV"
        #elseif os(iOS)
            "iPhone"
        #else
            "Computer"
        #endif
    }
}
