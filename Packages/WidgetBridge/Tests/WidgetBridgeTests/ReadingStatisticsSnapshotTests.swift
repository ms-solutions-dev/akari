import Foundation
import Testing

@testable import WidgetBridge

@Suite("Schnappschuss „Lesestatistik\"")
struct ReadingStatisticsSnapshotTests {

    private let calendar: Calendar = {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return k
    }()

    /// Saturday, 19.09.2026, 14:30 in Berlin.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 14, minute: 30))!
    }

    private func tag(
        _ daysBack: Int, book: TimeInterval = 0, manga: TimeInterval = 0, audiobook: TimeInterval = 0,
        pages: Int = 0
    ) -> ReadingStatisticsSnapshot.Day {
        let date = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: now))!
        return ReadingStatisticsSnapshot.Day(
            date: date, book: book, manga: manga, audiobook: audiobook, pages: pages)
    }

    /// Fourteen days: today 32 min book, yesterday 40 min manga, the day before 60 min
    /// audiobook, six days ago 10 min, seven days ago 90 min (outside the week).
    private var snapshot: ReadingStatisticsSnapshot {
        var days: [ReadingStatisticsSnapshot.Day] = []
        for daysBack in stride(from: 13, through: 0, by: -1) {
            switch daysBack {
            case 0: days.append(tag(0, book: 32 * 60))
            case 1: days.append(tag(1, manga: 40 * 60, pages: 120))
            case 2: days.append(tag(2, audiobook: 60 * 60))
            case 6: days.append(tag(6, book: 10 * 60))
            case 7: days.append(tag(7, book: 90 * 60, pages: 50))
            default: days.append(tag(daysBack))
            }
        }
        return ReadingStatisticsSnapshot(
            profile: "Alex", days: days, finishedMonth: 1,
            finishedYear: 4, stalled: 2, written: now)
    }

    @Test("Today, week and seven days — rolling, the day seven days ago no longer counts")
    func week() {
        let w = snapshot.week(asOf: now, calendar: calendar)
        #expect(w.days.count == 7)
        #expect(w.today == 32 * 60)
        #expect(w.week == (32 + 40 + 60 + 10) * 60)
        #expect(w.readingDays == 4, "today, yesterday, the day before, six days ago")
        #expect(w.pages == 120)
        #expect(w.days.last?.book == TimeInterval(32 * 60))
        #expect(w.days[5].manga == 40 * 60)
        #expect(w.days[4].audiobook == 60 * 60)
        #expect(w.days.first?.book == TimeInterval(10 * 60))
        #expect(abs(w.fractionToday - 32.0 / 142.0) < 0.0001)
    }

    @Test("At midnight “today” drops to 0, the week moves on, the oldest reading day drops out")
    func midnight() {
        let s = snapshot
        let midnight = ReadingStatisticsSnapshot.nextMidnight(to: now, calendar: calendar)
        #expect(calendar.component(.hour, from: midnight) == 0)
        #expect(calendar.component(.day, from: midnight) == 20)
        let w = s.week(asOf: midnight, calendar: calendar)
        #expect(w.today == 0)
        #expect(w.days.last?.total == TimeInterval(0))
        #expect(w.days[5].book == 32 * 60)
        #expect(w.week == (32 + 40 + 60) * 60)
        #expect(w.readingDays == 3)
    }

    @Test("A week without the app: the bars come from the retained days, what is missing is 0")
    func weekChange() {
        let s = snapshot
        let inSixDays = calendar.date(byAdding: .day, value: 6, to: now)!
        let w = s.week(asOf: inSixDays, calendar: calendar)
        #expect(w.days.first?.book == TimeInterval(32 * 60))
        #expect(w.week == 32 * 60)
        #expect(w.today == 0)
        #expect(w.readingDays == 1)
        let inTwentyDays = calendar.date(byAdding: .day, value: 20, to: now)!
        #expect(s.week(asOf: inTwentyDays, calendar: calendar).week == 0)
    }

    @Test("The retained history is capped at fourteen days — the oldest drop")
    func retainedDays() {
        let days = (0..<20).reversed().map { tag($0, book: 60) }
        let s = ReadingStatisticsSnapshot(profile: "M", days: days)
        #expect(s.days.count == ReadingStatisticsSnapshot.retainedDays)
        #expect(s.days.last?.date == calendar.startOfDay(for: now))
    }

    @Test("Empty is empty, without a reading day")
    func empty() {
        let s = ReadingStatisticsSnapshot.empty(profile: "Kim")
        #expect(s.empty)
        #expect(s.week(asOf: now, calendar: calendar).week == 0)
        #expect(s.week(asOf: now, calendar: calendar).readingDays == 0)
        let single = ReadingStatisticsSnapshot(profile: "M", days: [tag(0, book: 60)])
        #expect(!single.empty)
        #expect(single.week(asOf: now, calendar: calendar).readingDays == 1)
    }

    @Test("A snapshot from before the rework (with streak) can still be read")
    func oldVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lesezeit-\(UUID().uuidString)")
        try SnapshotStore.writeStatistics(snapshot, in: folder)
        let file = folder.appending(path: "statistik.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["serie"] = 3
        json["serieBis"] = json["geschrieben"]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let read = try #require(SnapshotStore.readStatistics(from: folder))
        #expect(read.week(asOf: now, calendar: calendar).readingDays == 4)
    }

    @Test("Writing and reading — round trip, with a date per day")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lesezeit-\(UUID().uuidString)")
        let s = snapshot
        try SnapshotStore.writeStatistics(s, in: folder)
        let read = try #require(SnapshotStore.readStatistics(from: folder))
        #expect(read.days.count == s.days.count)
        #expect(read.finishedMonth == 1)
        #expect(read.finishedYear == 4)
        #expect(read.stalled == 2)
        #expect(read.days[12].pages == 120)
        #expect(read.profile == "Alex")
        let w = read.week(asOf: now, calendar: calendar)
        #expect(w.today == 32 * 60)
        #expect(w.readingDays == 4)
        #expect(SnapshotStore.readStatistics(from: folder.appending(path: "nix")) == nil)
    }
}
