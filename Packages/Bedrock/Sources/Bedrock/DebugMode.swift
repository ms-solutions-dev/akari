import Foundation

/// Whether the app records verbosely.
///
/// **Why it exists.** The trace holds fifty entries and was meant for failures.
/// That is not enough when hunting for a stutter: there you want to know what
/// happened the whole time, not only what went wrong. Recording everything all
/// the time would be just as wrong, though: a home screen fills the fifty slots
/// in seconds, and the one line that matters falls out the back.
///
/// Hence a switch. Off means: only failures and conspicuously slow requests, as
/// before. On means: additionally every playback with samples, every connection
/// measurement and every mark set.
///
/// It lives in the settings under "Diagnostics" and is explicitly **not** meant
/// to be permanent. The reminder is right at the switch.
public struct DebugMode: Sendable, Equatable {

    public var isOn: Bool

    public init(isOn: Bool = false) {
        self.isOn = isOn
    }

    static let storageKey = "diagnostics.debug"

    public static func load(from store: any KeyValueStore) -> DebugMode {
        DebugMode(isOn: (try? store.value(for: storageKey)) == "1")
    }

    /// Loads the stored state and makes it the effective one, at app launch.
    ///
    /// **The bug that was here:** the only writer of ``current`` was the tap in the
    /// settings. After every restart the value was back to off, whatever the store
    /// said: the switch showed on, and the app recorded sparsely. A setting that
    /// does not survive a restart is none; that is why this call belongs at launch,
    /// before the first recording occurs.
    public static func activate(from store: any KeyValueStore) {
        current = load(from: store)
    }

    public func save(to store: any KeyValueStore) {
        try? store.set(isOn ? "1" : "0", for: Self.storageKey)
    }

    /// The currently effective state, for places without access to the store.
    ///
    /// The same reasoning as for ``Theme/current``: it is read in many places and
    /// only read, written in exactly one. The assertion is not "doesn't matter" but
    /// "is set from one thread".
    public nonisolated(unsafe) static var current = DebugMode()
}
