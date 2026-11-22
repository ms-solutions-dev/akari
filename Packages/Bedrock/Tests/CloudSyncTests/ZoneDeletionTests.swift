import Foundation
import Testing

@testable import CloudSync

/// **A deleted zone does not come back:** the owner had chosen "Delete Data" on
/// the iPhone in the iOS settings, and the profile still stood in the app; the
/// next pass recreated the zone and wrote the mirror up again. Every other device
/// did the same after one had deleted the zone.
@Suite("ProfileZone: deleted zones")
@MainActor
struct ZoneDeletionTests {

    let server = CloudMock()
    let identifier = UUID()

    var own: ZoneID { ZoneID(profile: identifier) }
    var serverZone: ZoneID { ZoneID(profile: identifier, owner: "alex") }

    func makeRecord(_ name: String, _ value: String) -> CloudRecord {
        CloudRecord(type: "Profileinstellung", name: name, fields: ["wert": .text(value)])
    }

    func zone(file: URL? = nil) -> ProfileZone {
        ProfileZone(file: file, service: server.access("alex"), zone: own, unprompted: false)
    }

    /// A zone that has been at the server once.
    func synced(file: URL? = nil) async -> ProfileZone {
        let z = zone(file: file)
        z.write(makeRecord("name", "Alex"))
        await z.equalSince()
        #expect(server.zoneList().count == 1)
        return z
    }

    @Test("Deleted by the user: no recreating, the mirror is gone, and it is reported")
    func byUser() async {
        let z = await synced()
        var reported: [ZoneRemoval] = []
        z.onRemoval = { reported.append($0) }
        server.eraseByUser(own, user: "alex")

        z.write(makeRecord("farbe", "indigo"))
        await z.equalSince()

        #expect(server.zoneList().isEmpty, "the zone is not recreated")
        #expect(z.allRecords(ofType: "Profileinstellung").isEmpty, "the mirror is discarded")
        #expect(z.state == .lost && z.removed == .byUser && z.pending == 0)
        #expect(reported == [.byUser])

        // A further pass no longer goes to the server and does not report again.
        z.write(makeRecord("farbe", "pflaume"))
        await z.equalSince()
        #expect(server.zoneList().isEmpty && reported == [.byUser])
    }

    /// Even a device that has never seen the zone does not simply recreate one the
    /// user deleted; Apple requires asking first.
    @Test("Deleted by the user, on a new device: likewise no recreating")
    func byUserOnNewDevice() async {
        _ = await synced()
        server.eraseByUser(own, user: "alex")
        let new = zone()
        new.write(makeRecord("name", "Alex"))
        await new.equalSince()
        #expect(server.zoneList().isEmpty && new.removed == .byUser)
    }

    /// **The counter test against the old code:** another device of the same Apple ID
    /// deletes the zone (like "Delete all iCloud data" in the app); this one sees
    /// only `zoneNotFound` and revived it with its mirror until now.
    @Test("Deleted remotely: do not revive, mirror stays, locked, reported")
    func fromRemote() async throws {
        let iphone = await synced()
        var reported: [ZoneRemoval] = []
        iphone.onRemoval = { reported.append($0) }
        try await server.access("alex").erase(own)

        iphone.write(makeRecord("farbe", "indigo"))
        await iphone.equalSince()

        #expect(server.zoneList().isEmpty)
        #expect(iphone.state == .lost && iphone.removed == .fromRemote)
        #expect(iphone.allRecords(ofType: "Profileinstellung").count == 2, "what lies here is up to the app")
        #expect(reported == [.fromRemote])
    }

    @Test("The lock survives the restart")
    func lockOnDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "wolke.json")
        _ = await synced(file: file)
        try await server.access("alex").erase(own)
        let first = zone(file: file)
        await first.equalSince()
        #expect(first.removed == .fromRemote)

        let second = zone(file: file)
        #expect(second.state == .lost && second.removed == .fromRemote)
        second.write(makeRecord("farbe", "indigo"))
        await second.equalSince()
        #expect(server.zoneList().isEmpty)
    }

    /// A mirror from before this rule carries no "confirmed"; its token says it.
    @Test("An older mirror with a token counts as confirmed")
    func oldSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "wolke.json")
        _ = await synced(file: file)
        // Remove the field, as an older mirror did not have it.
        var json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["bestaetigt"] != nil)
        json["bestaetigt"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        try await server.access("alex").erase(own)
        let z = zone(file: file)
        await z.equalSince()
        #expect(server.zoneList().isEmpty && z.removed == .fromRemote)
    }

    @Test("The first pass of a new profile still creates the zone")
    func firstPass() async {
        let z = zone()
        z.write(makeRecord("name", "Neu"))
        await z.equalSince()
        #expect(server.zoneList().count == 1 && z.removed == nil)
    }

    /// After the app's decision it continues empty, even after a deletion by the
    /// user. Only what was written afterwards goes up.
    @Test("Discarding starts over empty and creates the zone anew")
    func discard() async {
        let z = await synced()
        server.eraseByUser(own, user: "alex")
        z.onRemoval = { _ in z.drop() }
        await z.equalSince()
        #expect(z.removed == nil && server.zoneList().isEmpty)

        z.write(makeRecord("farbe", "indigo"))
        await z.equalSince()
        #expect(server.content(serverZone).map(\.name) == ["farbe"], "only the new one, not the old name")
        guard case .synced = z.state else {
            Issue.record("State \(z.state)")
            return
        }
    }

    /// The silent push brings the deletion before a pass notices it.
    @Test("The hub reports a deleted own zone from the database changes")
    func fromTheDatabase() async {
        let hub = CloudHub(
            service: server.access("alex"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "TV", model: "AppleTV"))
        let z = await synced()
        hub.register(z)
        await hub.checkDatabases()
        var reported: [ZoneRemoval] = []
        z.onRemoval = { reported.append($0) }

        server.eraseByUser(own, user: "alex")
        await hub.checkDatabases()
        #expect(reported == [.byUser] && z.allRecords(ofType: "Profileinstellung").isEmpty)
    }

    /// The device that deleted and started over itself does not lock on its own push.
    @Test("After the own restart the push of the deletion does not lock")
    func ownRestart() async throws {
        let hub = CloudHub(
            service: server.access("alex"), file: nil,
            device: DeviceDescription(identifier: "tv", name: "TV", model: "AppleTV"))
        let z = await synced()
        hub.register(z)
        await hub.checkDatabases()
        try await hub.erase(own)
        z.drop()
        await hub.checkDatabases()
        #expect(z.removed == nil)
    }

    @Test("Unbinding lifts the lock")
    func unbindLiftsLock() async {
        let z = await synced()
        server.eraseByUser(own, user: "alex")
        await z.equalSince()
        #expect(z.removed == .byUser)
        z.unbind()
        #expect(z.removed == nil && z.state == .unbound)
    }
}
