import Foundation
import SourcesKit
import Testing

@testable import ReadingProgress

@Suite("Reading time")
struct ReadingTimeTests {
    let identifier = TitleID(source: SourceID(provider: .komga, server: "comics.example"), id: "1")
    let start = Date(timeIntervalSince1970: 1_789_600_000)

    @Test("Comic: page turning does not count, reading does, a pause ends the session")
    func comic() {
        var z = ReadingTimeCounter(identifier: identifier, kind: .manga)
        var t = start
        // Page turning: ten pages at two seconds each is not reading.
        for n in 1...10 {
            if n > 1 { t += 2 }
            z.report(.page(n, from: 200), now: t)
        }
        #expect(z.ongoing == nil)
        // Reading: 20 pages at 40 s each.
        for n in 11...30 {
            t += 40
            #expect(z.report(.page(n, from: 200), now: t) == nil)
        }
        let s = try! #require(z.ongoing as ReadingSession?)
        #expect(s.readingTime == 800)
        #expect(s.pages == 20)
        #expect(abs(s.fraction - 0.1) < 0.001, "page 10 to 30 of 200")
        // A 20-minute pause, then on: the old session comes back, a new one begins.
        t += 20 * 60
        let done = z.report(.page(31, from: 200), now: t)
        #expect(done?.readingTime == 800)
        #expect(z.ongoing == nil)
        t += 60
        z.report(.page(32, from: 200), now: t, completed: true)
        let remainder = z.finish()
        #expect(remainder?.readingTime == 60 && remainder?.completed == true)
        #expect(z.finish() == nil)
    }

    @Test("Under 30 seconds is no session; the book counts in fractions; the audiobook counts the gap")
    func thresholds() {
        var z = ReadingTimeCounter(identifier: identifier, kind: .manga)
        z.report(.page(1, from: 100), now: start)
        z.report(.page(2, from: 100), now: start + 20)
        #expect(z.finish() == nil, "20 s is too little")

        var b = ReadingTimeCounter(identifier: identifier, kind: .book)
        b.report(.position(cfi: "a", fraction: 0.10), now: start)
        b.report(.position(cfi: "b", fraction: 0.12), now: start + 15)
        b.report(.position(cfi: "c", fraction: 0.14), now: start + 15 + 90)
        b.report(.position(cfi: "d", fraction: 0.16), now: start + 15 + 90 + 90)
        let closed = b.finish()
        let book = try! #require(closed)
        #expect(book.readingTime == 180, "15 s was page turning")
        #expect(abs(book.fraction - 0.04) < 0.0001)
        #expect(book.pages == 0)

        var h = ReadingTimeCounter(identifier: identifier, kind: .audiobook)
        var t = start
        for i in 0..<20 {
            h.report(.second(Double(i) * 15, from: 36_000), now: t)
            t += 15
        }
        #expect(h.ongoing?.readingTime == 285, "19 gaps of 15 s")
        t += 60 * 60
        let earlier = h.report(.second(9_000, from: 36_000), now: t)
        #expect(earlier?.readingTime == 285, "an hour's pause ends the session, the jump does not count")
    }

    @Test("The log: add, replace, cap, read from disk")
    @MainActor
    func log() throws {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "lesezeit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = ReadingTimeLog(file: file)
        var s = ReadingSession(
            identifier: identifier, kind: .book, startTime: start, end: start + 100, readingTime: 100)
        log.save(s)
        s.readingTime = 400
        log.save(s)
        #expect(log.sessions.count == 1 && log.sessions[0].readingTime == 400)
        let reopened = ReadingTimeLog(file: file)
        #expect(reopened.sessions == log.sessions)
        reopened.erase()
        #expect(ReadingTimeLog(file: file).sessions.isEmpty)
        // The cap, in memory only: 5,000 writes to disk take a minute.
        let many = ReadingTimeLog(file: nil)
        for i in 0..<(ReadingTimeLog.limit + 10) {
            many.save(
                ReadingSession(
                    identifier: identifier, kind: .manga, startTime: start, end: start + Double(i),
                    readingTime: 1))
        }
        #expect(many.sessions.count == ReadingTimeLog.limit)
        #expect(many.sessions.first?.end == start + 10, "the oldest drop")
    }

    @Test("The statistics: week with gapless days, per kind, streak up to yesterday")
    func statistics() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: start)
        let now = today + 12 * 3600
        func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today)! + 20 * 3600 }
        let other = TitleID(source: identifier.source, id: "2")
        let sessions = [
            ReadingSession(
                identifier: identifier, kind: .manga, startTime: day(1) - 600, end: day(1), readingTime: 600,
                pages: 30),
            ReadingSession(
                identifier: other, kind: .book, startTime: day(2) - 900, end: day(2), readingTime: 900,
                completed: true),
            ReadingSession(
                identifier: other, kind: .book, startTime: day(3) - 300, end: day(3), readingTime: 300),
            ReadingSession(
                identifier: identifier, kind: .audiobook, startTime: day(10) - 3600, end: day(10),
                readingTime: 3600),
        ]
        let week = ReadingStatistics(sessions, period: .week, now: now, calendar: calendar)
        #expect(week.readingTime == 1800)
        #expect(week.perKind == [.manga: 600, .book: 1200])
        #expect(week.pages == 30)
        #expect(week.completed == 1)
        #expect(week.days.count == 7)
        #expect(week.days.last?.readingTime == 0, "nothing yet today")
        #expect(week.days[5].readingTime == 600, "yesterday the manga")
        #expect(week.series == 3, "yesterday and the two days before; today does not count against it yet")
        #expect(week.longest == 900)
        let total = ReadingStatistics(sessions, period: .total, now: now, calendar: calendar)
        #expect(total.readingTime == 5400 && total.days.count == 11)
        #expect(total.title.count == 2)
    }
}
