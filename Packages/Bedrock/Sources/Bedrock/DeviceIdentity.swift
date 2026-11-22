import Foundation

/// The one device identifier by which the server recognizes this television.
///
/// **One source, and it persists.** Before, two places wanted to produce the
/// same identifier: the sign-in read it from the defaults and created it on
/// demand; the app launch read it too but created **nothing**, rolling a fresh
/// one on every run. On first launch two identifiers ran side by side: the server
/// listed the television twice, and the playback session hung on a device the
/// sign-in had never seen.
///
/// Hence a single path for both: read, otherwise create **and store**. Whoever
/// asks first creates; whoever asks afterwards gets the same one.
public enum DeviceIdentity {

    static let storageKey = "device.id"

    /// Returns the stored identifier, or creates one and stores it.
    public static func id(in defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: storageKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: storageKey)
        return fresh
    }

    /// Adopts an identifier that was stored under a **different** name.
    ///
    /// **What for:** the phone kept the same identifier under `app.deviceID`. Simply
    /// switching to this building block would find nothing and roll a fresh one, and
    /// **the media server sees a new device**. It keeps sessions per device; the old
    /// sign-in stays behind as a device that never comes back, and the running
    /// playback hangs on an identifier nobody knows. This is exactly what the head
    /// of this file warns about, only for "two names over time" instead of "two
    /// places in one app".
    ///
    /// **The name belongs to the caller.** This building block serves three
    /// programs; which old key lay where is known only to the program that had it.
    /// What lives here is the rule: **adopt as long as nothing exists under the new
    /// name**, and never overwrite, because an already issued identifier is known to
    /// the server.
    ///
    /// - Returns: `true` if something was actually adopted, for the test and for a
    ///   line in the diagnostics.
    @discardableResult
    public static func adopt(
        from oldKey: String, in defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.string(forKey: storageKey) == nil,
            let previous = defaults.string(forKey: oldKey), !previous.isEmpty
        else { return false }

        defaults.set(previous, forKey: storageKey)
        return true
    }
}
