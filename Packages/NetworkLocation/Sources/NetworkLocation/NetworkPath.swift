/// What the phone is currently connected through.
///
/// **"Expensive" is its own attribute and not the same as cellular.** A hotspot is Wi-Fi
/// and still expensive; so is a corporate Wi-Fi with a data cap. The system reports both
/// separately, and anyone who lumps them together will later mistake a hotspot for a
/// home network.
public struct NetworkPath: Sendable, Equatable, Hashable {

    public enum Kind: String, Sendable, CaseIterable {
        case wifi = "wlan"
        case cellular = "mobilfunk"
        case wired = "kabel"
        /// Something that cannot be classified: **only ever set, never reported.**
        ///
        /// A tunnel used to be translated to this, which hid airplane mode: a full tunnel
        /// leaves its interface standing when nothing carries it any more. Since then
        /// what counts is what carries underneath the tunnel; see
        /// ``NetworkPath/init(_:)`` in `NetworkWatch.swift`.
        case other = "anderes"
        case none = "keines"
    }

    public let kind: Kind

    /// The system considers this connection expensive: cellular or hotspot.
    public let expensive: Bool

    /// The viewer has switched on "Low Data Mode".
    ///
    /// An explicit request, not a guess about the line. It therefore outweighs any
    /// measurement of our own.
    public let sparing: Bool

    public init(kind: Kind, expensive: Bool = false, sparing: Bool = false) {
        self.kind = kind
        self.expensive = expensive
        self.sparing = sparing
    }

    public static let none = NetworkPath(kind: .none)

    /// Whether anything works at all.
    public var usable: Bool { kind != .none }

    /// Whether large amounts of data are acceptable right now.
    ///
    /// The offline store asks here, and the answer is deliberately strict: when in doubt,
    /// not downloading means a postponed film; downloading means a bill.
    public var largeAmountsAcceptable: Bool {
        usable && !expensive && !sparing
    }
}
