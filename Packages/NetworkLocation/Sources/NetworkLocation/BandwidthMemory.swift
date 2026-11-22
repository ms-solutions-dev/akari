import Foundation

/// What the line carried most recently.
///
/// **Tied to the network path, not to the clock.** On a TV a measured value stays valid
/// for six hours; for a device that leaves the house that is the wrong binding. A
/// measurement on the home Wi-Fi says nothing about the Wi-Fi in a café, and both are
/// called "Wi-Fi".
///
/// The way out is the counter from ``NetworkWatch``: a value holds as long as the path
/// has not changed. When it changes, the measurement is invalid: not old, but **about
/// something else**.
public struct BandwidthMemory: Sendable, Equatable {

    private struct Note: Sendable, Equatable {
        let mbit: Double
        let state: Int
    }

    private var notes: [NetworkPath: Note] = [:]

    public init() {}

    /// Remembers a measurement for the path it was taken on.
    public mutating func save(_ mbit: Double, route: NetworkPath, state: Int) {
        guard mbit > 0 else { return }
        notes[route] = Note(mbit: mbit, state: state)
    }

    /// What was measured last, or `nil` if something else has been in place since.
    public func value(route: NetworkPath, state: Int) -> Double? {
        guard let note = notes[route], note.state == state else { return nil }
        return note.mbit
    }

    /// Throws everything away. After a change of provider or channel list.
    public mutating func forget() {
        notes.removeAll()
    }

    /// Whether a resolution tier is acceptable at this state.
    ///
    /// Without a measurement nothing is guessed: the answer is `nil`, and the call site
    /// says "not measured yet" instead of inventing a number.
    public func usable(_ mbit: Double, route: NetworkPath, state: Int) -> Bool? {
        guard let measured = value(route: route, state: state) else { return nil }
        return measured >= mbit
    }
}
