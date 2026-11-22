import Foundation
import Testing

@testable import CloudSync

/// The hub: zone choice when binding, sharing from account to account, pushes,
/// account change, device list.
@Suite("CloudHub")
@MainActor
struct CloudHubTests {

    let server = CloudMock()

    func hub(_ user: String, device: String = "Alex's iPhone") -> CloudHub {
        CloudHub(
            service: server.access(user, name: user.capitalized), file: nil,
            device: DeviceDescription(identifier: "geraet-\(device)", name: device, model: "iPhone"))
    }

    func zone(_ user: String) -> ProfileZone {
        ProfileZone(file: nil, service: server.access(user), unprompted: false)
    }

    @Test("Binding: the first device creates the zone, the second with the same name takes it")
    func zoneChoice() async throws {
        let iphone = hub("alex", device: "iPhone")
        let z1 = zone("alex")
        z1.write(CloudRecord(type: "Merkeintrag", name: "m1", fields: [:]))
        let k1 = try #require(await iphone.bind(z1, identifier: UUID(), name: "Alex", color: "indigo"))
        #expect(k1.isProfile && !k1.shared)
        #expect(z1.record(type: "Profileinstellung", name: "name")?["wert"]?.text == "Alex")

        let ipad = hub("alex", device: "iPad")
        let z2 = zone("alex")
        z2.write(CloudRecord(type: "Merkeintrag", name: "m2", fields: [:]))
        let k2 = try #require(await ipad.bind(z2, identifier: UUID(), name: " alex ", color: "pflaume"))
        #expect(k2 == k1, "the same reader on the same Apple ID")
        #expect(Set(z2.allRecords(ofType: "Merkeintrag").map(\.name)) == ["m1", "m2"], "both states merged")
        #expect(CloudHub.devices(in: z2).map(\.name).sorted() == ["iPad", "iPhone"])

        // A different name gets a zone of its own.
        let z3 = zone("alex")
        let k3 = try #require(await ipad.bind(z3, identifier: UUID(), name: "Sam", color: nil))
        #expect(k3 != k1 && server.zoneList().count == 2)
    }

    @Test("Without an account the zone stays unbound")
    func withoutAccount() async {
        server.setAccount("alex", .noAccount)
        let z = zone("alex")
        #expect(await hub("alex").bind(z, identifier: UUID(), name: "Alex", color: nil) == nil)
        #expect(z.zone == nil && z.state == .unbound)
    }

    @Test("Sharing: share, accept, read along and write along, withdraw")
    func sharing() async throws {
        let ownerHub = hub("alex")
        let own = zone("alex")
        let identifier = try #require(
            await ownerHub.bind(own, identifier: UUID(), name: "Alex", color: "indigo"))
        own.write(CloudRecord(type: "Lesesitzung", name: "s1", fields: ["ende": .time(Date())]))
        await own.equalSince()
        let sharing = try await ownerHub.share(identifier, title: "Alex")
        let url = try #require(sharing.url)
        #expect(sharing.participant.count == 1 && sharing.participant[0].owner)

        // The family iPad on a different Apple ID accepts.
        let family = hub("familie", device: "iPad")
        let accepted = try await family.accept(url: url)
        #expect(
            accepted.zone.owner == "alex" && accepted.profileName == "Alex"
                && accepted.color == "indigo")
        #expect(accepted.ownerName == "Alex")
        let foreign = ProfileZone(
            file: nil, service: server.access("familie"), zone: accepted.zone, unprompted: false)
        _ = await family.bind(foreign, identifier: UUID(), name: "Alex", color: nil)
        #expect(foreign.allRecords(ofType: "Lesesitzung").map(\.name) == ["s1"])
        #expect(CloudHub.devices(in: foreign).count == 2)
        foreign.write(CloudRecord(type: "Lesesitzung", name: "s2", fields: ["ende": .time(Date())]))
        await foreign.equalSince()
        // The owner gets the push for their private database and fetches.
        ownerHub.register(own)
        #expect(await ownerHub.process(push: ["attrappe-geteilt": false]))
        #expect(Set(own.allRecords(ofType: "Lesesitzung").map(\.name)) == ["s1", "s2"])
        #expect(await ownerHub.process(push: ["fremd": true]) == false)

        // Participant list at the owner, then withdraw: the iPad loses the zone.
        let list = try #require(try await ownerHub.sharing(identifier))
        #expect(list.invited.map(\.identifier) == ["familie"])
        try await ownerHub.remove(participant: "familie", from: identifier)
        family.register(foreign)
        _ = await family.process(push: ["attrappe-geteilt": true])
        #expect(foreign.state == .lost)
        await foreign.equalSince()
        #expect(foreign.state == .lost, "a foreign zone is not recreated")
        #expect(own.allRecords(ofType: "Lesesitzung").count == 2, "the data stays with the owner")
    }

    @Test("The participant leaves the share; the owner ends it completely")
    func leave() async throws {
        let ownerHub = hub("alex")
        let own = zone("alex")
        let identifier = try #require(await ownerHub.bind(own, identifier: UUID(), name: "Alex", color: nil))
        let url = try #require(try await ownerHub.share(identifier, title: "Alex").url)
        let family = hub("familie")
        let accepted = try await family.accept(url: url)
        try await family.leave(accepted.zone)
        #expect(try await ownerHub.sharing(identifier)?.invited.isEmpty == true)
        let invitee = hub("sam")
        _ = try await invitee.accept(url: url)
        try await ownerHub.endSharing(identifier)
        #expect(try await ownerHub.sharing(identifier) == nil)
        #expect(try await server.access("sam").zones(shared: true).isEmpty)
    }

    @Test("Renaming devices: a human's name stays, the system name does not come back")
    func renameDevices() async throws {
        let iphone = hub("alex", device: "iPhone")
        let z = zone("alex")
        _ = try #require(await iphone.bind(z, identifier: UUID(), name: "Alex", color: nil))
        let identifier = iphone.device.identifier
        #expect(CloudHub.devices(in: z).first?.named == false)
        // Another device of the same zone renames the iPhone.
        iphone.renameDevice(identifier, name: " Alex's Handy ", in: z)
        await z.equalSince()
        let entry = try #require(CloudHub.devices(in: z).first { $0.identifier == identifier })
        #expect(entry.name == "Alex's Handy" && entry.named)
        // The iPhone registers itself again later, with the assigned name, not "iPhone".
        z.write(
            CloudRecord(
                type: CloudHub.deviceType, name: identifier,
                fields: [
                    "name": .text("Alex's Handy"), "modell": .text("iPhone"), "benannt": .truth(true),
                    "zuletzt": .time(Date().addingTimeInterval(-7200)),
                ]))
        iphone.writeDevice(in: z)
        let after = try #require(CloudHub.devices(in: z).first { $0.identifier == identifier })
        #expect(after.name == "Alex's Handy" && after.named)
        #expect(Date().timeIntervalSince(after.recently) < 60, "only `recently` moves")
        // An unknown device gets no record merely by renaming.
        iphone.renameDevice("fremd", name: "Irgendwas", in: z)
        #expect(CloudHub.devices(in: z).count == 1)
        // An empty name changes nothing.
        iphone.renameDevice(identifier, name: "   ", in: z)
        #expect(CloudHub.devices(in: z).first?.name == "Alex's Handy")
    }

    @Test(
        "Teilnehmer und Geräte: der Ersteller des Geräte-Datensatzes ist der Teilnehmer, und er ist benennbar"
    )
    func participantDevices() async throws {
        let ownerHub = hub("alex", device: "iPhone")
        let own = zone("alex")
        let identifier = try #require(await ownerHub.bind(own, identifier: UUID(), name: "Alex", color: nil))
        let url = try #require(try await ownerHub.share(identifier, title: "Alex").url)
        let family = hub("familie", device: "iPad")
        let accepted = try await family.accept(url: url)
        let foreign = ProfileZone(
            file: nil, service: server.access("familie"), zone: accepted.zone, unprompted: false)
        _ = await family.bind(foreign, identifier: UUID(), name: "Alex", color: nil)
        await own.equalSince()
        let sharing = try #require(try await ownerHub.sharing(identifier))
        let participant = try #require(sharing.invited.first)
        #expect(CloudHub.devices(from: participant.identifier, in: own).map(\.name) == ["iPad"])
        #expect(CloudHub.devices(from: "alex", in: own).map(\.name) == ["iPhone"])
        #expect(CloudHub.participantName(participant.identifier, in: own) == nil)
        ownerHub.renameParticipant(participant.identifier, name: "Die Eltern", in: own)
        await own.equalSince()
        #expect(CloudHub.participantName(participant.identifier, in: own) == "Die Eltern")
        // The participant sees their name too, and the creator stays when rewriting.
        await foreign.equalSince()
        #expect(CloudHub.participantName(participant.identifier, in: foreign) == "Die Eltern")
        ownerHub.renameDevice(family.device.identifier, name: "iPad der Eltern", in: own)
        await own.equalSince()
        #expect(
            CloudHub.devices(from: participant.identifier, in: own).map(\.name) == ["iPad der Eltern"])
        ownerHub.renameParticipant(participant.identifier, name: "", in: own)
        #expect(CloudHub.participantName(participant.identifier, in: own) == nil)
    }

    /// Waits until `condition` holds, at most two seconds. The mock announces account changes
    /// to the hub's account watch, which calls ``CloudHub/accountChanged()`` on its own task —
    /// concurrently with the call the test makes itself. A zone that is already in a pass answers
    /// the second call with "again afterwards" and returns at once, so the state may settle a
    /// few scheduler turns later. What is asserted stays the same: the state *is* reached.
    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("Account change: signed out means no account, signed in fetches again")
    func accountChange() async throws {
        let ownerHub = hub("alex")
        await ownerHub.launch()
        #expect(ownerHub.account == .available)
        let z = zone("alex")
        _ = await ownerHub.bind(z, identifier: UUID(), name: "Alex", color: nil)
        ownerHub.register(z)
        server.setAccount("alex", .noAccount)
        await ownerHub.accountChanged()
        #expect(await eventually { ownerHub.account == .noAccount && z.state == .noAccount })
        server.setAccount("alex", .available)
        await ownerHub.accountChanged()
        let synced = await eventually {
            if case .synced = z.state { return true }
            return false
        }
        #expect(synced, "State \(z.state)")
    }

    @Test("A share link is one from icloud.com/share")
    func shareLink() {
        #expect(CloudHub.isShareLink(URL(string: "https://www.icloud.com/share/0abc#Alex")!))
        #expect(!CloudHub.isShareLink(URL(string: "akari://einrichten?komga=x")!))
    }
}
