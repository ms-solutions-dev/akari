import Foundation
import Testing

@testable import CloudSync

/// The zone as a mirror with a queue against the mock: write, up, down, conflict,
/// offline, remote deletion, zone lost.
@Suite("ProfileZone")
@MainActor
struct ProfileZoneTests {

    let server = CloudMock()
    let identifier = UUID()

    func makeRecord(_ name: String, _ value: String, type: String = "Profileinstellung") -> CloudRecord {
        CloudRecord(type: type, name: name, fields: ["wert": .text(value)])
    }

    func zone(_ user: String = "alex", file: URL? = nil) -> ProfileZone {
        ProfileZone(
            file: file, service: server.access(user), zone: ZoneID(profile: identifier),
            unprompted: false)
    }

    @Test("A write is in the mirror at once, goes up on the pass and arrives at the other device")
    func upload() async throws {
        let iphone = zone()
        iphone.write(makeRecord("theme", "indigo"))
        #expect(iphone.record(type: "Profileinstellung", name: "theme")?["wert"]?.text == "indigo")
        #expect(iphone.pending == 1 && iphone.state == .neverSynced)
        await iphone.equalSince()
        #expect(iphone.pending == 0)
        guard case .synced = iphone.state else {
            Issue.record("State \(iphone.state)")
            return
        }
        #expect(server.content(ZoneID(profile: identifier, owner: "alex")).count == 1)

        let ipad = zone()
        var reported: [CloudRecord] = []
        let observation = ipad.observe("Profileinstellung") { reported = $0 }
        await ipad.equalSince()
        #expect(ipad.allRecords(ofType: "Profileinstellung").map(\.name) == ["theme"])
        #expect(reported.count == 1)
        withExtendedLifetime(observation) {}
    }

    @Test("Offline the queue waits; when the server is back, everything goes up")
    func offline() async {
        let z = zone()
        server.reachable = false
        z.write(makeRecord("theme", "pflaume"))
        await z.equalSince()
        #expect(z.state == .unreachable && z.pending == 1)
        server.reachable = true
        await z.equalSince()
        #expect(z.pending == 0)
        #expect(
            server.content(ZoneID(profile: identifier, owner: "alex")).first?["wert"]?.text == "pflaume")
    }

    @Test("Without an account everything stays local, and the line says so")
    func noAccount() async {
        let z = zone()
        server.setAccount("alex", .noAccount)
        z.write(makeRecord("theme", "tinte"))
        await z.equalSince()
        #expect(z.state == .noAccount && z.pending == 1)
        #expect(z.allRecords(ofType: "Profileinstellung").count == 1)
    }

    @Test("Conflict: the younger change wins, for sessions the later end")
    func conflict() async {
        let iphone = zone()
        let ipad = zone()
        iphone.write(makeRecord("theme", "indigo"), now: Date(timeIntervalSince1970: 100))
        await iphone.equalSince()
        await ipad.equalSince()
        // Both change, the iPad goes up first; the iPhone has the younger intent.
        ipad.write(makeRecord("theme", "pflaume"), now: Date(timeIntervalSince1970: 200))
        iphone.write(makeRecord("theme", "terrakotta"), now: Date(timeIntervalSince1970: 300))
        await ipad.equalSince()
        await iphone.equalSince()
        #expect(iphone.record(type: "Profileinstellung", name: "theme")?["wert"]?.text == "terrakotta")
        #expect(iphone.pending == 0)
        await ipad.equalSince()
        #expect(ipad.record(type: "Profileinstellung", name: "theme")?["wert"]?.text == "terrakotta")

        // Sessions: the later end wins, even if it is the older change.
        iphone.rule(for: "Lesesitzung", .largerValue("ende"))
        ipad.rule(for: "Lesesitzung", .largerValue("ende"))
        let session = CloudRecord(
            type: "Lesesitzung", name: "s1", fields: ["ende": .time(Date(timeIntervalSince1970: 900))])
        iphone.write(session, now: Date(timeIntervalSince1970: 1000))
        await iphone.equalSince()
        await ipad.equalSince()
        var longer = session
        longer["ende"] = .time(Date(timeIntervalSince1970: 1500))
        ipad.write(longer, now: Date(timeIntervalSince1970: 1100))
        var shorter = session
        shorter["ende"] = .time(Date(timeIntervalSince1970: 1200))
        iphone.write(shorter, now: Date(timeIntervalSince1970: 1300))
        await ipad.equalSince()
        await iphone.equalSince()
        #expect(
            iphone.record(type: "Lesesitzung", name: "s1")?["ende"]?.time
                == Date(timeIntervalSince1970: 1500))
    }

    @Test("Deletion travels, but not across a pending write")
    func delete() async {
        let iphone = zone()
        let ipad = zone()
        iphone.write(makeRecord("a", "1", type: "Merkeintrag"))
        iphone.write(makeRecord("b", "2", type: "Merkeintrag"))
        await iphone.equalSince()
        await ipad.equalSince()
        #expect(ipad.allRecords(ofType: "Merkeintrag").count == 2)
        iphone.eraseAll(type: "Merkeintrag")
        await iphone.equalSince()
        // The iPad touched b once more offline: b stays, a drops.
        ipad.write(makeRecord("b", "3", type: "Merkeintrag"))
        await ipad.equalSince()
        #expect(ipad.allRecords(ofType: "Merkeintrag").map(\.name) == ["b"])
        await iphone.equalSince()
        #expect(iphone.allRecords(ofType: "Merkeintrag").map(\.name) == ["b"])
    }

    @Test("The mirror survives the restart, queue and token included")
    func disk() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "wolke-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.reachable = false
        let first = zone(file: file)
        first.write(makeRecord("theme", "indigo"))
        await first.equalSince()
        let second = zone(file: file)
        #expect(second.pending == 1 && second.allRecords(ofType: "Profileinstellung").count == 1)
        server.reachable = true
        await second.equalSince()
        #expect(second.pending == 0)
        let third = zone(file: file)
        #expect(third.state != .neverSynced, "the token and the last pass are on disk")
    }

    @Test("An own zone that does not exist is created, mirror included")
    func zoneMissing() async {
        let z = zone()
        z.write(makeRecord("theme", "indigo"))
        #expect(server.zoneList().isEmpty)
        await z.equalSince()
        #expect(server.zoneList().count == 1 && z.pending == 0)
    }

    @Test("Export is readable JSON without a seal")
    func export() async throws {
        let z = zone()
        z.write(makeRecord("theme", "indigo"))
        await z.equalSince()
        let data = try #require(z.export())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"indigo\"") && !text.contains("siegel"))
    }
}

/// A record the server rejects on its own (type or field missing in the
/// production schema) does not drag its batch along and does not block the
/// queue.
@Suite("ProfileZone: individual rejection")
@MainActor
struct ProfileZoneRejectionTests {

    let server = CloudMock()
    let identifier = UUID()

    var serverZone: ZoneID { ZoneID(profile: identifier, owner: "alex") }
    let newcomer = RecordName(type: "Neuling", name: "n")

    func makeRecord(_ name: String, _ value: String, type: String = "Profileinstellung") -> CloudRecord {
        CloudRecord(type: type, name: name, fields: ["wert": .text(value)])
    }

    func zone(file: URL? = nil) -> ProfileZone {
        ProfileZone(
            file: file, service: server.access("alex"), zone: ZoneID(profile: identifier),
            unprompted: false)
    }

    @Test(
        "Ein Typ ohne Schema trifft nur seinen Satz: die anderen sind oben, er ist vermerkt, die Schlange frei"
    )
    func onlyItsRecord() async {
        server.deny(type: "Neuling")
        let z = zone()
        z.write(makeRecord("a", "1"))
        z.write(makeRecord("n", "neu", type: "Neuling"))
        z.write(makeRecord("b", "2"))
        await z.equalSince()

        #expect(server.content(serverZone).map(\.name) == ["a", "b"])
        #expect(z.pending == 0, "the rejected record does not block the queue")
        #expect(z.rejected[newcomer] != nil, "and it is noted, not silently gone")
        #expect(z.record(type: "Neuling", name: "n")?["wert"]?.text == "neu", "it stays in the mirror")
        guard case .synced = z.state else {
            Issue.record("State \(z.state)")
            return
        }

        // The next pass runs through instead of getting stuck on the same record.
        z.write(makeRecord("a", "3"))
        await z.equalSince()
        #expect(server.content(serverZone).first { $0.name == "a" }?["wert"]?.text == "3")
        #expect(z.pending == 0)

        // Whoever deletes the record themselves no longer wants it; the note drops with it.
        z.erase(type: "Neuling", name: "n")
        #expect(z.rejected.isEmpty)
    }

    @Test("After the schema deployment the record goes up on the next write, the note drops")
    func nextWrite() async {
        server.deny(type: "Neuling")
        let z = zone()
        z.write(makeRecord("n", "neu", type: "Neuling"))
        await z.equalSince()
        #expect(z.rejected[newcomer] != nil && server.content(serverZone).isEmpty)

        server.deny(type: "Neuling", reason: nil)
        z.write(makeRecord("n", "neuer", type: "Neuling"))
        await z.equalSince()
        #expect(server.content(serverZone).first?["wert"]?.text == "neuer")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    @Test("The note survives the restart, and the restart tries the record once more")
    func restart() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "wolke-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        server.deny(type: "Neuling")
        let first = zone(file: file)
        first.write(makeRecord("n", "neu", type: "Neuling"))
        await first.equalSince()
        #expect(first.pending == 0)

        server.deny(type: "Neuling", reason: nil)
        let second = zone(file: file)
        #expect(second.rejected[newcomer] != nil && second.pending == 1)
        await second.equalSince()
        #expect(server.content(serverZone).map(\.name) == ["n"])
        #expect(second.rejected.isEmpty && second.pending == 0)
    }

    /// One pass carries at most conflict rounds × batch records up. What lies above
    /// that used to say "synced" anyway.
    @Test("More records than one pass carries: synced only when the queue is empty")
    func bigMigration() async throws {
        let z = zone()
        let count = ProfileZone.conflictRounds * ProfileZone.batch + 50
        for i in 0..<count { z.write(makeRecord("s\(i)", "\(i)")) }
        await z.equalSince()
        #expect(z.pending == 0)
        guard case .synced = z.state else {
            Issue.record("State \(z.state)")
            return
        }
        #expect(server.content(ZoneID(profile: identifier, owner: "alex")).count == count)
    }

    @Test("Share link only from icloud.com, not from similar hosts")
    func shareLinkHost() throws {
        let genuine = try #require(URL(string: "https://www.icloud.com/share/abc"))
        let bare = try #require(URL(string: "https://icloud.com/share/abc"))
        let wrong = try #require(URL(string: "https://evilicloud.com/share/abc"))
        #expect(CloudHub.isShareLink(genuine))
        #expect(CloudHub.isShareLink(bare))
        #expect(!CloudHub.isShareLink(wrong))
    }
}
