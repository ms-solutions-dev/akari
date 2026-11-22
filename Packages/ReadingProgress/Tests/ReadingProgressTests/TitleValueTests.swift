import Foundation
import SourcesKit
import Testing

@testable import ReadingProgress

/// The statistics per title: time, sessions, pages, name from the youngest session;
/// pace as pages or fraction per hour; "about … left" from the current state.
@Suite("Statistics per title")
struct TitleValueTests {

    let komga = SourceID(provider: .komga, server: "comics.example")
    let grimmory = SourceID(provider: .grimmory, server: "buecher.example")
    let now = Date(timeIntervalSince1970: 1_789_600_000)

    var manga: TitleID { TitleID(source: komga, id: "47") }
    var book: TitleID { TitleID(source: grimmory, id: "1042") }

    func session(
        _ identifier: TitleID, kind: Kind, daysAgo days: Int, readingTime: TimeInterval, pages: Int = 0,
        fraction: Double = 0, completed: Bool = false, name: String? = nil
    ) -> ReadingSession {
        let end = now.addingTimeInterval(-Double(days) * 86_400)
        return ReadingSession(
            identifier: identifier, kind: kind, startTime: end - readingTime, end: end,
            readingTime: readingTime,
            pages: pages,
            fraction: fraction, completed: completed, name: name)
    }

    @Test(
        "Per title: time, sessions, pages, fraction summed, name from the youngest session, most time first"
    )
    func perTitle() throws {
        let sessions = [
            session(
                manga, kind: .manga, daysAgo: 1, readingTime: 1800, pages: 40, fraction: 0.2,
                name: "Pepper&Carrot · Volume 47"),
            session(
                manga, kind: .manga, daysAgo: 3, readingTime: 1200, pages: 25, fraction: 0.12,
                name: "Pepper&Carrot 37"),
            session(
                book, kind: .book, daysAgo: 2, readingTime: 7200, fraction: 0.15, completed: true,
                name: "Sherlock Holmes 02"),
            session(book, kind: .book, daysAgo: 40, readingTime: 600, fraction: 0.01),
        ]
        let week = ReadingStatistics(sessions, period: .week, now: now)
        #expect(week.titleValues.map(\.identifier) == [book, manga], "most time first")
        let m = try #require(week.titleValue(manga))
        #expect(m.readingTime == 3000 && m.sessions == 2 && m.pages == 65)
        #expect(abs(m.fraction - 0.32) < 0.0001)
        #expect(m.name == "Pepper&Carrot · Volume 47", "the youngest session names it")
        #expect(abs(m.recently.timeIntervalSince(now - 86_400)) < 1)
        #expect(!m.completed)
        let b = try #require(week.titleValue(book))
        #expect(b.sessions == 1 && b.completed, "the 40-day-old session is outside the week")
        #expect(week.finishedOnes.map(\.identifier) == [book])
        #expect(week.titleValues(.manga).map(\.identifier) == [manga])
        #expect(week.titleValues(nil).count == 2)
        let total = ReadingStatistics(sessions, period: .total, now: now)
        #expect(total.titleValue(book)?.sessions == 2)
    }

    @Test("Pace: pages per hour for manga, fraction per hour for books; none under five minutes")
    func pace() throws {
        let m = ReadingStatistics(
            [session(manga, kind: .manga, daysAgo: 1, readingTime: 1800, pages: 30, fraction: 0.15)],
            period: .week,
            now: now
        ).titleValues[0]
        #expect(m.pagesPerHour == 60)
        #expect(abs(try #require(m.fractionPerHour) - 0.3) < 0.0001)
        let b = ReadingStatistics(
            [session(book, kind: .book, daysAgo: 1, readingTime: 3600, fraction: 0.1)], period: .week,
            now: now
        ).titleValues[0]
        #expect(b.pagesPerHour == nil, "a book counts no pages")
        #expect(abs(try #require(b.fractionPerHour) - 0.1) < 0.0001)
        let short = ReadingStatistics(
            [session(book, kind: .book, daysAgo: 1, readingTime: 120, fraction: 0.05)], period: .week,
            now: now
        ).titleValues[0]
        #expect(short.fractionPerHour == nil && short.remainingTime(state: 0.5) == nil)
    }

    @Test("About … left: from state and pace; for manga via the pages when the length is known")
    func remainingTime() throws {
        let m = ReadingStatistics(
            [session(manga, kind: .manga, daysAgo: 1, readingTime: 1800, pages: 30, fraction: 0.15)],
            period: .week,
            now: now
        ).titleValues[0]
        // 60 pages per hour; 200 pages, 30 % read: 140 pages, so 2 h 20 min.
        #expect(abs(try #require(m.remainingTime(state: 0.3, pagesTotal: 200)) - 8400) < 1)
        // Without a length via the fraction: 0.3 per hour, 70 % open, so 2 h 20 min.
        #expect(abs(try #require(m.remainingTime(state: 0.3)) - 8400) < 1)
        let b = ReadingStatistics(
            [session(book, kind: .book, daysAgo: 1, readingTime: 3600, fraction: 0.1)], period: .week,
            now: now
        ).titleValues[0]
        #expect(abs(try #require(b.remainingTime(state: 0.6)) - 4 * 3600) < 1)
        #expect(b.remainingTime(state: 1) == nil, "finished is finished")
    }
}
