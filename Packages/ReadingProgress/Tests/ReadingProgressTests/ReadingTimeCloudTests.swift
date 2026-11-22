import CloudSync
import Foundation
import SourcesKit
import Testing

@testable import ReadingProgress

/// The log over the profile zone: one record per session, merged without duplicates, the
/// later end wins, deletion travels, the transition collects the old key.
@Suite("Reading time in the cloud")
struct ReadingTimeCloudTests {

    let server = CloudMock()
    let zoneID = ZoneID(profile: UUID())

    /// A zone "on one device": same identifier, same server, own mirror.
    @MainActor
    func zone() -> ProfileZone {
        ProfileZone(file: nil, service: server.access("alex"), zone: zoneID, unprompted: false)
    }

    let komga = SourceID(provider: .komga, server: "comics.example")
    let now = Date(timeIntervalSince1970: 1_789_600_000)

    func session(
        _ id: String, daysAgo days: Int, readingTime: TimeInterval = 1200,
        name: String? = "Pepper&Carrot · Volume 47"
    )
        -> ReadingSession
    {
        let end = now.addingTimeInterval(-Double(days) * 86_400)
        return ReadingSession(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-\(String(repeating: "0", count: 12 - id.count))\(id)")!,
            identifier: TitleID(source: komga, id: "0K7Q3XJ1-47"), kind: .manga, startTime: end - readingTime,
            end: end,
            readingTime: readingTime, pages: 30, fraction: 0.1234, name: name)
    }

    @Test("Pack and unpack: all fields come back, seconds rounded, fraction to four places")
    func roundTrip() throws {
        let before = [
            session("1", daysAgo: 1), session("2", daysAgo: 2, name: nil),
            ReadingSession(
                identifier: TitleID(
                    source: SourceID(provider: .grimmory, server: "buecher.example"), id: "1042"),
                kind: .book, startTime: now - 2400.4, end: now - 0.4, readingTime: 2400.4, fraction: 0.06789,
                completed: true, name: "The Memoirs of Sherlock Holmes"),
        ]
        let data = try #require(ReadingTimeCloud.pack(before, now: now))
        let after = try #require(ReadingTimeCloud.unpack(data))
        #expect(after.map(\.id) == [before[1].id, before[0].id, before[2].id], "sorted by end")
        #expect(after[0].name == nil && after[1].name == "Pepper&Carrot · Volume 47")
        #expect(after[2].completed && after[2].name == "The Memoirs of Sherlock Holmes")
        #expect(abs(after[2].fraction - 0.0679) < 0.00001)
        #expect(after[2].readingTime == 2400)
        #expect(abs(after[2].end.timeIntervalSince(now)) < 1)
        #expect(ReadingTimeCloud.unpack(Data("not zlib".utf8)) == nil)
    }

    @Test("The window: twelve months go up, older data stays local only")
    func window() throws {
        let all = [session("1", daysAgo: 10), session("2", daysAgo: 364), session("3", daysAgo: 366)]
        let data = try #require(ReadingTimeCloud.pack(all, now: now))
        let uploaded = try #require(ReadingTimeCloud.unpack(data))
        #expect(
            uploaded.map(\.id) == [all[1].id, all[0].id], "sorted by end, the 366-day-old one is missing")
    }

    @Test("The arithmetic: a year at five sessions a day stays far below the cap")
    func size() throws {
        var many: [ReadingSession] = []
        let sources = [
            (SourceID(provider: .komga, server: "comics.example"), Kind.manga, "Pepper&Carrot · Volume "),
            (SourceID(provider: .grimmory, server: "buecher.example"), Kind.book, "Sherlock Holmes 0"),
            (
                SourceID(provider: .audiobookshelf, server: "hoerbuch.example"), Kind.audiobook,
                "The Time Machine "
            ),
        ]
        for i in 0..<1825 {
            let (source, kind, name) = sources[i % 3]
            let end = now.addingTimeInterval(-Double(i) * 86_400 / 5)
            many.append(
                ReadingSession(
                    identifier: TitleID(source: source, id: "K\(i / 40)"), kind: kind,
                    startTime: end - 1500 - Double(i % 900),
                    end: end, readingTime: 1500 + Double(i % 900), pages: kind == .manga ? 20 + i % 30 : 0,
                    fraction: Double(i % 100) / 1000, completed: i % 40 == 39, name: name + String(i / 40)))
        }
        let data = try #require(ReadingTimeCloud.pack(many, now: now))
        let raw = try JSONEncoder().encode(many.map(ReadingTimeCloud.Item.init))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let ordinary = try encoder.encode(many)
        // Measured: 291 B ordinary, 140 B compact, 41 B compressed per session; the figures
        // in the DocC of `ReadingTimeCloud`.
        #expect(ordinary.count / many.count > 250, "\(ordinary.count / many.count) bytes ordinary")
        #expect(raw.count / many.count < 160, "\(raw.count / many.count) bytes compact")
        #expect(data.count / many.count < 60, "\(data.count / many.count) bytes compressed")
        #expect(data.count < 100 * 1024, "compressed \(data.count) bytes for 1,825 sessions")
        #expect(ReadingTimeCloud.unpack(data)?.count == many.count)
    }

    @Test("The cap: if it does not fit, the oldest drop")
    func cap() throws {
        let all = (0..<100).map { session(String($0), daysAgo: 100 - $0) }
        let data = try #require(ReadingTimeCloud.pack(all, now: now, cap: 500))
        let uploaded = try #require(ReadingTimeCloud.unpack(data))
        #expect(data.count <= 500)
        #expect(!uploaded.isEmpty && uploaded.count < 100)
        #expect(uploaded.last?.id == all.last?.id, "the youngest stays")
        #expect(uploaded.map(\.end) == uploaded.map(\.end).sorted())
    }

    @Test("Two logs merge via the session identifier; the longer version wins")
    @MainActor
    func merging() async throws {
        let cloudIphone = zone()
        let iphone = ReadingTimeLog(file: nil, cloud: cloudIphone)
        iphone.save(session("a", daysAgo: 3))
        var ongoing = session("b", daysAgo: 1, readingTime: 600)
        iphone.save(ongoing)
        await cloudIphone.equalSince()
        #expect(server.content(ZoneID(name: zoneID.name, owner: "alex")).count == 2)

        // The iPad has a session of its own and reads the zone in when syncing.
        let cloudIpad = zone()
        let ipad = ReadingTimeLog(file: nil, cloud: cloudIpad)
        ipad.save(session("c", daysAgo: 2))
        await cloudIpad.equalSince()
        #expect(
            Set(ipad.sessions.map(\.id))
                == Set([session("a", daysAgo: 0), ongoing, session("c", daysAgo: 0)].map(\.id)))

        // The iPhone fetches: c is added, nothing doubled.
        await cloudIphone.equalSince()
        #expect(iphone.sessions.count == 3)
        // The running session keeps growing on the iPhone; the iPad takes the longer one.
        ongoing.readingTime = 1800
        ongoing.end = ongoing.end + 1200
        iphone.save(ongoing)
        await cloudIphone.equalSince()
        await cloudIpad.equalSince()
        #expect(ipad.sessions.count == 3)
        #expect(ipad.sessions.first { $0.id == ongoing.id }?.readingTime == 1800)
        #expect(ipad.cloudState == .sessions(3, youngest: ongoing.end))
        // Another profile has another zone and does not know the first profile's sessions.
        let otherZone = ProfileZone(
            file: nil, service: server.access("alex"), zone: ZoneID(profile: UUID()),
            unprompted: false)
        let other = ReadingTimeLog(file: nil, cloud: otherZone)
        other.save(session("e", daysAgo: 1))
        await otherZone.equalSince()
        #expect(other.sessions.count == 1, "the other log does not know the first profile's sessions")
    }

    @Test("Deletion travels: when the zone's records disappear, the other device deletes too")
    @MainActor
    func deleting() async {
        let cloudIphone = zone()
        let iphone = ReadingTimeLog(file: nil, cloud: cloudIphone)
        iphone.save(session("a", daysAgo: 3))
        await cloudIphone.equalSince()
        let cloudIpad = zone()
        let ipad = ReadingTimeLog(file: nil, cloud: cloudIpad)
        await cloudIpad.equalSince()
        #expect(ipad.sessions.count == 1)
        iphone.erase()
        await cloudIphone.equalSince()
        #expect(server.content(ZoneID(name: zoneID.name, owner: "alex")).isEmpty)
        await cloudIpad.equalSince()
        #expect(ipad.sessions.isEmpty)
        #expect(ipad.cloudState == .empty)
    }

    @Test("The transition collects the old key and removes it; data older than twelve months stays local")
    @MainActor
    func transition() async throws {
        let legacy = StorageMock()
        let data = try #require(ReadingTimeCloud.pack([session("a", daysAgo: 3)], now: Date()))
        legacy.values["profil.alex.lesezeit"] = data
        let file = FileManager.default.temporaryDirectory.appending(
            path: "lesezeit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let ancient = ReadingSession(
            identifier: TitleID(source: komga, id: "x"), kind: .manga, startTime: now - 400 * 86_400 - 600,
            end: now - 400 * 86_400, readingTime: 600)
        ReadingTimeLog(file: file).save(ancient)
        let w = zone()
        let log = ReadingTimeLog(
            file: file, cloud: w,
            legacyData: LegacyData(legacy, lookupKey: ReadingTimeLog.cloudKey(profile: "alex")))
        #expect(legacy.values.isEmpty, "the key is gone")
        #expect(log.sessions.count == 2)
        await w.equalSince()
        let uploaded = server.content(ZoneID(name: zoneID.name, owner: "alex"))
        #expect(
            uploaded.map(\.name) == [session("a", daysAgo: 0).id.uuidString],
            "the ancient session stays down")
        // A restart reads file and mirror: nothing doubled, nothing gone.
        let reopened = ReadingTimeLog(file: file, cloud: w)
        #expect(reopened.sessions.count == 2)
    }

    @Test("A log without a cloud writes nothing up; old logs without names stay readable")
    @MainActor
    func withoutCloud() throws {
        let log = ReadingTimeLog(file: nil)
        log.save(session("a", daysAgo: 1))
        #expect(log.sessions.count == 1 && log.cloudState == .withoutCloud)
        let old = Data(
            """
            [{"id":"00000000-0000-0000-0000-000000000009","kennung":{"quelle":{"anbieter":"komga","server":"comics.example"},"id":"1"},"art":"manga","beginn":"2026-09-01T10:00:00Z","ende":"2026-09-01T10:30:00Z","lesezeit":1800,"seiten":40,"anteil":0.2,"abgeschlossen":false}]
            """.utf8)
        let file = FileManager.default.temporaryDirectory.appending(
            path: "lesezeit-alt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try old.write(to: file)
        let read = ReadingTimeLog(file: file)
        #expect(read.sessions.count == 1 && read.sessions[0].name == nil)
    }

    @Test("Record and session: all fields there and back")
    func record() throws {
        let s = ReadingSession(
            identifier: TitleID(
                source: SourceID(provider: .grimmory, server: "buecher.example"), id: "1042"),
            kind: .book, startTime: now - 2400, end: now, readingTime: 2400.5, pages: 3, fraction: 0.06789,
            completed: true, name: "The Memoirs of Sherlock Holmes")
        let back = try #require(ReadingTimeLog.session(from: ReadingTimeLog.makeRecord(s)))
        #expect(back == s)
        #expect(
            ReadingTimeLog.session(from: CloudRecord(type: "Lesesitzung", name: "kaputt", fields: [:])) == nil
        )
    }
}
