import Foundation
import Library
import OfflineStore
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import Testing
import WidgetBridge

@testable import Features

@Suite("Widgets \"Continue listening\" and \"Reading statistics\"")
@MainActor
struct WidgetListenStatisticsTests {

    private let calendar: Calendar = {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return k
    }()

    /// Saturday, 19 Sep 2026, 14:30 in Berlin.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 14, minute: 30))!
    }

    private let listenSource = SourceID(provider: .audiobookshelf, server: "hoerbuch.example")

    private func audiobook(_ id: String, duration: TimeInterval = 10_000, cover: Bool = true) -> Title {
        Title(
            identifier: TitleID(source: listenSource, id: id), kind: .audiobook, name: "Hörbuch \(id)",
            authors: ["Mary Shelley"],
            cover: cover ? URL(string: "https://hoerbuch.example/cover/\(id)") : nil,
            scope: .duration(duration), narrator: ["Sprecher"])
    }

    private func session(
        _ kind: Kind, daysAgo: Int, minutes: Double, id: String = "t", name: String? = nil,
        hourOfDay: Int = 20,
        pages: Int = 0, completed: Bool = false
    ) -> ReadingSession {
        let tag = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        let end = min(calendar.date(bySettingHour: hourOfDay, minute: 0, second: 0, of: tag)!, now)
        return ReadingSession(
            identifier: TitleID(source: listenSource, id: id), kind: kind, startTime: end - minutes * 60,
            end: end,
            readingTime: minutes * 60, pages: pages, fraction: 0.1, completed: completed, name: name)
    }

    // MARK: - Reading time

    @Test(
        "Daily values per kind, pages, reading days, finished per segment, stalled, fourteen days without gaps"
    )
    func readingTimeDailyValues() {
        let sessions = [
            session(.book, daysAgo: 0, minutes: 20, hourOfDay: 9),
            session(.book, daysAgo: 0, minutes: 12, hourOfDay: 13),
            session(.manga, daysAgo: 1, minutes: 40, id: "m1", pages: 120, completed: true),
            session(.audiobook, daysAgo: 2, minutes: 60),
            session(.book, daysAgo: 9, minutes: 15, id: "b9", pages: 0, completed: true),
            session(.book, daysAgo: 30, minutes: 99, id: "alt", completed: true),
            session(.manga, daysAgo: 8, minutes: 5, id: "m8", pages: 30),
        ]
        let s = ReadingStatisticsSnapshot.from(
            sessions, stalled: 2, profile: "Alex", multipleProfiles: true, now: now,
            calendar: calendar)
        #expect(s.days[12].pages == 120)
        #expect(s.days[5].pages == 30)
        #expect(s.finishedMonth == 2)
        #expect(s.finishedYear == 3)
        #expect(s.stalled == 2)
        #expect(s.days.count == ReadingStatisticsSnapshot.retainedDays)
        #expect(s.days.last?.book == TimeInterval(32 * 60))
        #expect(s.days.last?.manga == TimeInterval(0))
        #expect(s.days[12].manga == 40 * 60)
        #expect(s.days[11].audiobook == 60 * 60)
        #expect(s.days[4].book == 15 * 60)
        let sum: TimeInterval = s.days.reduce(0) { $0 + $1.total }
        #expect(sum == 152 * 60)
        #expect(s.profile == "Alex")
        #expect(s.multipleProfiles)
        let w = s.week(asOf: now, calendar: calendar)
        #expect(w.today == 32 * 60)
        #expect(w.week == 132 * 60)
        #expect(w.pages == 120)
        #expect(w.readingDays == 3, "today, yesterday, the day before; eight and nine days ago do not count")
        let sheet = ReadingStatistics(sessions, period: .week, now: now, calendar: calendar)
        #expect(
            w.readingDays == sheet.days.filter { $0.readingTime > 0 }.count,
            "same as reading days in the sheet")
        let midnight = ReadingStatisticsSnapshot.nextMidnight(to: now, calendar: calendar)
        let inSixDays = calendar.date(byAdding: .day, value: 5, to: midnight)!
        #expect(s.week(asOf: inSixDays, calendar: calendar).pages == 0)
    }

    @Test("Reading days roll on without the app: days only drop out after seven days")
    func readingDaysRollOver() {
        let sessions = [
            session(.manga, daysAgo: 1, minutes: 40),
            session(.audiobook, daysAgo: 2, minutes: 60),
        ]
        let s = ReadingStatisticsSnapshot.from(
            sessions, profile: "M", multipleProfiles: false, now: now, calendar: calendar)
        let midnight = ReadingStatisticsSnapshot.nextMidnight(to: now, calendar: calendar)
        #expect(s.week(asOf: now, calendar: calendar).readingDays == 2, "without reading today they stay")
        #expect(s.week(asOf: midnight, calendar: calendar).readingDays == 2)
        let inFive = calendar.date(byAdding: .day, value: 4, to: midnight)!
        #expect(s.week(asOf: inFive, calendar: calendar).readingDays == 1)
        let inSix = calendar.date(byAdding: .day, value: 5, to: midnight)!
        #expect(s.week(asOf: inSix, calendar: calendar).readingDays == 0)
    }

    @Test(
        "Week rollover: whatever is older than seven days drops out of the week but stays in the offline store"
    )
    func weekRollover() {
        let sessions = [session(.book, daysAgo: 7, minutes: 50), session(.book, daysAgo: 6, minutes: 10)]
        let s = ReadingStatisticsSnapshot.from(
            sessions, profile: "M", multipleProfiles: false, now: now, calendar: calendar)
        #expect(s.days[6].book == 50 * 60)
        let w = s.week(asOf: now, calendar: calendar)
        #expect(w.week == 10 * 60)
        let tomorrow = ReadingStatisticsSnapshot.nextMidnight(to: now, calendar: calendar)
        #expect(s.week(asOf: tomorrow, calendar: calendar).week == 0)
    }

    @Test("Without a session the snapshot is empty")
    func readingTimeEmpty() {
        let s = ReadingStatisticsSnapshot.from(
            [], profile: "Kim", multipleProfiles: true, now: now, calendar: calendar)
        #expect(s.empty)
        #expect(s.week(asOf: now, calendar: calendar).readingDays == 0)
        #expect(s.finishedYear == 0)
    }

    @Test("The reading-time writer stores the file and does not write the same twice")
    func readingTimeWriter() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lesezeit-\(UUID().uuidString)")
        let writer = ReadingStatisticsWriter(folder: folder)
        // The writer computes with the real clock, so the session ends just now
        // rather than on a fixed 19 Sep (the check broke on 20 Sep when "today" moved on).
        let end = Date().addingTimeInterval(-60)
        let sessions = [
            ReadingSession(
                identifier: TitleID(source: listenSource, id: "t"), kind: .book, startTime: end - 20 * 60,
                end: end,
                readingTime: 20 * 60, fraction: 0.1)
        ]
        writer.schedule(
            ReadingStatisticsWriter.Job(
                sessions: sessions, stalled: 1, profile: "Alex", multipleProfiles: false))
        writer.immediately()
        let read = try #require(SnapshotStore.readStatistics(from: folder))
        #expect(read.days.last?.book == TimeInterval(20 * 60))
        #expect(read.week(asOf: Date()).readingDays == 1)
        #expect(read.stalled == 1)
        let stamp =
            try FileManager.default.attributesOfItem(
                atPath: folder.appending(path: "statistik.json").path)[.modificationDate] as? Date
        writer.schedule(
            ReadingStatisticsWriter.Job(
                sessions: sessions, stalled: 1, profile: "Alex", multipleProfiles: false))
        writer.immediately()
        let stamp2 =
            try FileManager.default.attributesOfItem(
                atPath: folder.appending(path: "statistik.json").path)[.modificationDate] as? Date
        #expect(stamp == stamp2)
    }

    // MARK: - Continue listening

    @Test("From the player: name, author, chapter, position, pace, running, link, cover")
    func fromPlayer() {
        let title = audiobook("li_1")
        let state = PlayerState(
            title: title, chapter: "Kapitel 4", time: 3_600, duration: 10_000, tempo: 1.25, running: true)
        let s = ContinueListeningSnapshot.from(
            player: state, reading: nil, profile: "Alex", multipleProfiles: false, now: now)
        let h = s.audiobook!
        #expect(h.id == "audiobookshelf@hoerbuch.example/li_1")
        #expect(h.name == "Hörbuch li_1")
        #expect(h.subline == "Mary Shelley")
        #expect(h.chapter == "Kapitel 4")
        #expect(h.time == 3_600)
        #expect(h.duration == 10_000)
        #expect(h.tempo == 1.25)
        #expect(h.running)
        #expect(Deeplink(h.link) == .read(title.identifier))
        #expect(h.cover == ContinueReadingSnapshot.coverFilename(for: title.identifier.description))
        let remainder: TimeInterval = 10_000 - 3_600 - 75
        #expect(s.remainder(asOf: now.addingTimeInterval(60)) == remainder)
    }

    @Test(
        "Without a player: the most recent listening reading on the shelf, from the state with second or share"
    )
    func fromReading() {
        let withSecond = Shelf.Reading(
            title: audiobook("a"),
            state: ReadingState(position: .second(2_500, from: 9_000), timestamp: now))
        let s = ContinueListeningSnapshot.from(
            player: nil, reading: withSecond, profile: "M", multipleProfiles: false, now: now)
        #expect(s.audiobook?.time == 2_500)
        #expect(s.audiobook?.duration == 9_000)
        #expect(s.audiobook?.running == false)
        #expect(s.audiobook?.chapter == nil)
        let withShare = Shelf.Reading(
            title: audiobook("b", duration: 4_000),
            state: ReadingState(position: .fraction(0.25), timestamp: now))
        let t = ContinueListeningSnapshot.from(
            player: nil, reading: withShare, profile: "M", multipleProfiles: false, now: now)
        #expect(t.audiobook?.time == 1_000)
        #expect(t.audiobook?.duration == 4_000)
        #expect(abs(t.fraction(asOf: now) - 0.25) < 0.0001)
        let empty = ContinueListeningSnapshot.from(
            player: nil, reading: nil, profile: "M", multipleProfiles: false)
        #expect(empty.audiobook == nil)
    }

    @Test("The player wins over the reading, and the job changes only in five-minute steps")
    func job() {
        let title = audiobook("li_1")
        let reading = Shelf.Reading(
            title: audiobook("alt"), state: ReadingState(position: .second(10, from: 100), timestamp: now))
        let a = ContinueListeningWriter.Job(
            player: PlayerState(
                title: title, chapter: "1", time: 100, duration: 1_000, tempo: 1, running: true),
            reading: reading, profile: "M", multipleProfiles: false)
        let b = ContinueListeningWriter.Job(
            player: PlayerState(
                title: title, chapter: "1", time: 250, duration: 1_000, tempo: 1, running: true),
            reading: reading, profile: "M", multipleProfiles: false)
        let c = ContinueListeningWriter.Job(
            player: PlayerState(
                title: title, chapter: "1", time: 310, duration: 1_000, tempo: 1, running: true),
            reading: reading, profile: "M", multipleProfiles: false)
        let d = ContinueListeningWriter.Job(
            player: PlayerState(
                title: title, chapter: "1", time: 100, duration: 1_000, tempo: 1, running: false),
            reading: reading, profile: "M", multipleProfiles: false)
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
        let s = ContinueListeningSnapshot.from(
            player: a.player, reading: a.reading, profile: "M", multipleProfiles: false)
        #expect(s.audiobook?.id == title.identifier.description)
    }

    @Test("The listening writer stores JSON, without network without cover, and anew on profile switch")
    func listenWriterWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hoeren-\(UUID().uuidString)")
        let writer = ContinueListeningWriter(folder: folder, imageLoader: ImageLoader(folder: nil))
        let transport = MockTransport()
        let sources = SnapshotWriter.SourceAccess(
            headerLines: { _ in [:] }, transport: { _ in transport })
        let reading = Shelf.Reading(
            title: audiobook("a", cover: false),
            state: ReadingState(position: .second(2_500, from: 9_000), timestamp: now))
        writer.schedule(
            ContinueListeningWriter.Job(
                player: nil, reading: reading, profile: "Alex", multipleProfiles: true),
            sources: sources)
        await writer.immediately()
        let read = try #require(SnapshotStore.readContinueListening(from: folder))
        #expect(read.audiobook?.id == "audiobookshelf@hoerbuch.example/a")
        #expect(read.profile == "Alex")
        writer.schedule(
            ContinueListeningWriter.Job(player: nil, reading: nil, profile: "Kim", multipleProfiles: true),
            sources: sources)
        await writer.immediately()
        let empty = try #require(SnapshotStore.readContinueListening(from: folder))
        #expect(empty.audiobook == nil)
        #expect(empty.profile == "Kim")
    }
}
