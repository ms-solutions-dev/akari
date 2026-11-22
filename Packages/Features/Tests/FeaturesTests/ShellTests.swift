import AccountsKit
import Bedrock
import DesignSystem
import SwiftUI
import Testing

@testable import Features

@Suite("The shell")
@MainActor
struct ShellTests {
    @Test("Three areas, search last")
    func areas() {
        // The order is part of the design: Start on the left, Search as a magnifier on the right.
        #expect([Area.start, .library, .search].map(\.rawValue) == ["start", "bibliothek", "suche"])
    }

    @Test("A sidebar genre can be named, for probe and deep link")
    func genreArea() {
        #expect(Area(rawValue: "genre:buch:Thriller") == .genre(.book, .name("Thriller")))
        #expect(Area(rawValue: "genre:manga:-") == .genre(.manga, .without))
        #expect(
            Area(rawValue: "genre:buch:Science-Fiction: Klassiker")?.rawValue
                == "genre:buch:Science-Fiction: Klassiker")
        #expect(Area(rawValue: "genre:film:X") == nil)
        #expect(Area(rawValue: "genre:buch") == nil)
    }

    @Test("The dot: green goes, red needs the user, orange the server is missing, gray is nothing")
    func point() {
        #expect(AccountRow.signal(.signedIn) == .ok)
        #expect(AccountRow.signal(.expired) == .failure)
        #expect(AccountRow.signal(.disrupted) == .failure)
        #expect(AccountRow.signal(.unreachable) == .warning)
        #expect(AccountRow.signal(.notConfigured) == nil)
        #expect(AccountRow.signal(.unchecked) == nil)
        #expect(AccountRow.color(.notConfigured) == .secondary)
    }

    @Test("The shell takes a profile registry with mocks, without keychain")
    @MainActor
    func register() {
        let state = ProfileState()
        defer { state.tidyUp() }
        var built: [Int] = []
        _ = ShellView(
            profiles: state.profiles,
            context: { profile, persistence, device in
                built.append(profile.id)
                return state.context(profile, persistence, device)
            }, device: state.device)
        #expect(built == [1], "the context of the active profile, once")
        let context = state.context(state.profiles.active, state.profiles.activeStore, state.device)
        #expect(!context.accounts.configured)
        #expect(context.accounts.states.count == 4, "four servers; catalogs only once one is created")
        #expect(context.inventory.maxAge == nil)
    }
}
