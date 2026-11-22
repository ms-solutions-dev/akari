import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// The saved list without iCloud — order, store, sync with the server.
@Suite("Saved list")
@MainActor
struct SavedListTests {

    private let grimmory = SourceID(provider: .grimmory, server: "buecher.example")
    private let komga = SourceID(provider: .komga, server: "comics.example")

    private func persistence() -> UserDefaults {
        let name = "merkliste-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func title(_ id: String, _ source: SourceID? = nil) -> SaveTarget {
        .title(TitleID(source: source ?? grimmory, id: id))
    }

    @Test(
        "Merken hängt ans Ende, Vergessen nimmt heraus, doppelt zählt nicht — und alles steht in der Ablage")
    func saveAndStore() {
        let defaults = persistence()
        let list = SavedList(persistence: defaults, cloud: nil)
        #expect(list.entries.isEmpty)
        list.save(title("1"))
        list.save(title("2"))
        list.save(title("1"))
        list.save(.series(SeriesID(source: komga, id: "s1")))
        #expect(list.entries == [title("1"), title("2"), .series(SeriesID(source: komga, id: "s1"))])
        list.forget(title("2"))
        #expect(list.entries.count == 2)
        let reloaded = SavedList(persistence: defaults, cloud: nil)
        #expect(reloaded.entries == list.entries)
    }

    @Test("Dragging as in a SwiftUI list: down and up")
    func move() {
        let list = SavedList(persistence: persistence(), cloud: nil)
        for id in ["a", "b", "c", "d"] { list.save(title(id)) }
        list.move(from: [0], to: 3)
        #expect(list.entries == [title("b"), title("c"), title("a"), title("d")])
        list.move(from: [3], to: 0)
        #expect(list.entries == [title("d"), title("b"), title("c"), title("a")])
        list.remove(at: [1, 2])
        #expect(list.entries == [title("d"), title("a")])
    }

    @Test("The server has the last word for its source — other sources and series stay")
    func sync() {
        let list = SavedList(persistence: persistence(), cloud: nil)
        list.save(title("k1", komga))
        list.save(title("g1"))
        list.save(title("g2"))
        list.save(.series(SeriesID(source: grimmory, id: "s")))
        list.adopt(
            [TitleID(source: grimmory, id: "g2"), TitleID(source: grimmory, id: "g3")],
            source: grimmory)
        #expect(
            list.entries == [
                title("k1", komga), title("g2"), .series(SeriesID(source: grimmory, id: "s")),
                title("g3"),
            ])
    }
}
