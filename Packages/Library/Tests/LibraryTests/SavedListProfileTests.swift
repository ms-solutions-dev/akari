import CloudSync
import Foundation
import SourcesKit
import Testing

@testable import Library

/// The saved list per profile via the zone: two profiles, two zones; two
/// devices merge; forgetting travels; the migration fetches the old key.
@Suite("Saved list per profile")
@MainActor
struct SavedListProfileTests {

    private let grimmory = SourceID(provider: .grimmory, server: "buecher.example")
    private let server = CloudMock()
    private let alexs = ZoneID(profile: UUID())

    private func persistence() -> UserDefaults {
        let name = "merkliste-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func zone(_ identifier: ZoneID? = nil) -> ProfileZone {
        ProfileZone(file: nil, service: server.access("alex"), zone: identifier ?? alexs, unprompted: false)
    }

    private func title(_ id: String) -> SaveTarget { .title(TitleID(source: grimmory, id: id)) }

    @Test("Two profiles, two zones — and the other state comes from the zone")
    func twoProfiles() async {
        let wm = zone()
        let alex = SavedList(persistence: persistence(), cloud: wm)
        let ws = zone(ZoneID(profile: UUID()))
        let profileA = SavedList(persistence: persistence(), cloud: ws)
        alex.save(title("m1"))
        profileA.save(title("s1"))
        profileA.save(title("s2"))
        await wm.equalSince()
        await ws.equalSince()
        #expect(alex.entries == [title("m1")])
        #expect(profileA.entries == [title("s1"), title("s2")])
        // The same profile on the other device reads the state from the zone.
        let wIpad = zone()
        await wIpad.equalSince()
        let alexIpad = SavedList(persistence: persistence(), cloud: wIpad)
        #expect(alexIpad.entries == [title("m1")])
    }

    @Test("Two devices merge: saving is added, forgetting travels, the younger drag wins")
    func merge() async {
        let wIphone = zone()
        let iphone = SavedList(persistence: persistence(), cloud: wIphone)
        iphone.save(title("a"))
        iphone.save(title("b"))
        await wIphone.equalSince()
        let wIpad = zone()
        await wIpad.equalSince()
        let ipad = SavedList(persistence: persistence(), cloud: wIpad)
        #expect(ipad.entries == [title("a"), title("b")])
        ipad.save(title("c"))
        iphone.forget(title("a"))
        await wIpad.equalSince()
        await wIphone.equalSince()
        await wIpad.equalSince()
        #expect(iphone.entries == [title("b"), title("c")])
        #expect(ipad.entries == [title("b"), title("c")])
        ipad.move(from: IndexSet(integer: 1), to: 0)
        await wIpad.equalSince()
        await wIphone.equalSince()
        #expect(iphone.entries == [title("c"), title("b")])
    }

    @Test("The migration fetches the old key and removes it")
    func migration() async throws {
        let old = StorageMock()
        old.values["profil.alex.gemerkt"] = try JSONEncoder().encode([title("x"), title("y")])
        let w = zone()
        let list = SavedList(
            persistence: persistence(), cloud: w,
            legacyData: LegacyData(old, lookupKey: SavedList.cloudKey(profile: "alex")))
        #expect(old.values.isEmpty)
        #expect(list.entries == [title("x"), title("y")])
        await w.equalSince()
        #expect(server.content(ZoneID(name: alexs.name, owner: "alex")).count == 2)
        #expect(
            SavedList.name(title("x")) == SavedList.name(title("x")) && SavedList.name(title("x")).count == 64
        )
    }
}
