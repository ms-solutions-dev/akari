import Testing

@testable import NetworkLocation

@Suite("LocationStatement")
struct LocationStatementTests {

    /// The rule at stake: **never one shared sentence for all sources.** Exactly one of
    /// the three hangs off the tunnel, and a "slow connection" message would simply be
    /// wrong for two of three.
    @Test("No sentence appears in two places")
    func eachPlaceHasItsOwnSentence() {
        var seen: [String: LocationStatement.Place] = [:]
        for place in LocationStatement.Place.allCases {
            for location in [LocationStatement.Location.atHome, .onTheGo] {
                for source in LocationStatement.Source.allCases {
                    // **`atHome` and `onTheGo` are the two cases that have a sentence.**
                    // `unknown` yields nothing, so this uses a `guard` and not a `!`: a
                    // test that crashes on an intended gap reports the wrong failure.
                    guard
                        let lookupKey = LocationStatement.for(
                            place, location: location, source: source)?.lookupKey
                    else {
                        Issue.record("\(place) at \(location) has no sentence")
                        continue
                    }
                    if let earlier = seen[lookupKey] {
                        #expect(earlier == place, "\(lookupKey) appears at \(earlier) and at \(place)")
                    }
                    seen[lookupKey] = place
                }
            }
        }
    }

    @Test("Every situation has a sentence", arguments: LocationStatement.Place.allCases)
    func noGap(place: LocationStatement.Place) {
        for location in [LocationStatement.Location.atHome, .onTheGo] {
            #expect(LocationStatement.for(place, location: location)?.lookupKey.isEmpty == false)
        }
    }

    /// Only two places are really different on the go, and only those two are framed. A
    /// warning on every line would no longer be a warning.
    @Test("Warnings appear twice, not everywhere")
    func warnings() {
        var warnings = 0
        for place in LocationStatement.Place.allCases {
            for location in [LocationStatement.Location.atHome, .onTheGo] {
                for source in LocationStatement.Source.allCases {
                    if LocationStatement.for(place, location: location, source: source)?.warning == true {
                        warnings += 1
                    }
                }
            }
        }
        // Jellyfin on the go in the library, and "Automatic" in the sources sheet. The
        // sources sheet counts three times because the source changes nothing there.
        #expect(warnings == 4)
        #expect(LocationStatement.for(.library, location: .onTheGo, source: .jellyfin)?.warning == true)
        #expect(LocationStatement.for(.library, location: .onTheGo, source: .xtream)?.warning == false)
        #expect(LocationStatement.for(.sourceSheet, location: .onTheGo)?.warning == true)
        #expect(LocationStatement.for(.sourceSheet, location: .atHome)?.warning == false)
    }

    /// The occupied TV changes the sentence: it is not an addition tacked on but a
    /// different sentence. Two composed texts could not be translated into three
    /// languages.
    @Test("The occupied TV has its own sentence")
    func occupied() {
        let free = LocationStatement.for(.live, location: .atHome, tvOccupied: false)
        let occupied = LocationStatement.for(.live, location: .atHome, tvOccupied: true)
        #expect(free?.lookupKey != occupied?.lookupKey)
    }

    /// A child account may not see two of the three collections at all. A line listing
    /// them would be exactly the contradiction the search below avoids.
    @Test("The child account gets its own sentence")
    func childAccount() {
        let child = LocationStatement.for(.search, location: .atHome, childAccount: true)
        #expect(child?.lookupKey == "place.search.child")
        #expect(
            LocationStatement.for(.search, location: .onTheGo, childAccount: true)?.lookupKey
                == child?.lookupKey)
    }
}
