/// "What this source can do on the go": one sentence per source.
///
/// **Never one shared sentence for all.** Exactly one of the three sources hangs off the
/// tunnel, and that is the only one that can lower the resolution. A shared "slow
/// connection" message would be plainly wrong for two of three sources, and too vague
/// to act on for the third.
///
/// The sentences live in the string catalog.
public enum LocationStatement {

    /// Where the line is shown.
    public enum Place: String, CaseIterable, Sendable {
        case library = "bibliothek"
        case live
        case portals = "portale"
        case search = "suche"
        /// In the sources sheet, where "Automatic" has to be explained.
        case sourceSheet = "quellblatt"
    }

    /// Which collection is currently shown.
    public enum Source: String, CaseIterable, Sendable {
        case jellyfin
        case xtream
        case portals = "portale"
    }

    /// Whether the home network is reachable directly.
    ///
    /// **Not derivable from the network path.** Whether you are "at home" is not decided
    /// by whether Wi-Fi is present, but by whether the media server answers without a
    /// tunnel; a foreign Wi-Fi is Wi-Fi too. This information therefore comes from where
    /// the server is checked, not from the ``NetworkWatch``.
    public enum Location: String, Sendable {
        case atHome = "daheim"
        case onTheGo = "unterwegs"

        /// **Not decided yet, and then the line stays silent.**
        ///
        /// This case used to not exist, so `location: .atHome` was hard-coded in three
        /// places: live, portals and search claimed "at home" without anything having
        /// checked it. Anyone out and about read a statement about their network that came
        /// from one line of code.
        ///
        /// **A missing line is better than a wrong one.** The viewer notices that nothing
        /// is there; a wrong location line is only noticed after it has been believed.
        case unknown = "unbekannt"
    }

    /// A sentence and whether it is shown as a warning.
    public struct Statement: Sendable, Equatable {
        public let lookupKey: String
        /// Framed and with a golden icon, for the two places where being out and about
        /// really does change something.
        public let warning: Bool

        init(_ lookupKey: String, warning: Bool = false) {
            self.lookupKey = lookupKey
            self.warning = warning
        }
    }

    /// The sentence for this place.
    ///
    /// - Parameters:
    ///   - place: where the line is shown
    ///   - location: whether the home network is reachable directly
    ///   - source: which collection is shown (only relevant in the library)
    ///   - tvOccupied: whether the Apple TV holds the one permitted connection
    ///   - childAccount: for search: listing the three collections a child may not see
    ///     would be exactly the contradiction the search below avoids
    public static func `for`(
        _ place: Place,
        location: Location,
        source: Source = .jellyfin,
        tvOccupied: Bool = false,
        childAccount: Bool = false
    ) -> Statement? {
        // **Without a location, no location line.** Every statement in this file starts
        // with "at home or on the go"; without the answer there would only be a choice
        // between two claims. The caller then draws nothing; see ``Location/unknown``.
        guard location != .unknown else { return nil }
        let route = location == .onTheGo

        switch place {
        case .library:
            switch (source, route) {
            case (.jellyfin, false): return Statement("place.library.jellyfin.example")
            case (.jellyfin, true): return Statement("place.library.jellyfin.away", warning: true)
            case (.xtream, false), (.portals, false): return Statement("place.library.xtream.example")
            case (.xtream, true), (.portals, true): return Statement("place.library.xtream.away")
            }

        case .live:
            switch (route, tvOccupied) {
            case (false, false): return Statement("place.live.example")
            case (false, true): return Statement("place.live.example.busy")
            case (true, false): return Statement("place.live.away")
            case (true, true): return Statement("place.live.away.busy")
            }

        case .portals:
            return Statement(route ? "place.portals.away" : "place.portals.example")

        case .search:
            if childAccount { return Statement("place.search.child") }
            return Statement(route ? "place.search.away" : "place.search.example")

        case .sourceSheet:
            return route
                ? Statement("place.sources.away", warning: true)
                : Statement("place.sources.example")
        }
    }
}
