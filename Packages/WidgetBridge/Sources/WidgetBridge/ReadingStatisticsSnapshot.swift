import Foundation

/// The "Reading statistics" snapshot: the figures of the statistics sheet for the
/// **active** profile — reading time and pages per day and kind for the last two weeks,
/// the titles finished in the month and in the year, and how many titles were left lying.
///
/// **Why two weeks and not seven days, and why a date per day:** the widget computes
/// "today", "this week" and "pages this week" itself, for every entry of its timeline
/// (``week(asOf:calendar:)``). At midnight "today" drops to 0 and the week moves on one day —
/// without the app running. For that the retained history must be longer than what is shown; fourteen days cover a
/// week in which the app was not opened. The week is rolling (today and the
/// six days before), as in the statistics sheet — no Monday, no calendar week.
///
/// **Reading days instead of streaks** (no streaks): the widget counts the days
/// with reading time among the seven shown itself — the same counting as "reading days"
/// in the statistics sheet (week period), and at midnight it is right without the app.
///
/// **Finished and left-lying are states from the time of writing:** "finished in the month" is
/// the last 30 days, "in the year" the last 365 — like the segments of the sheet. They
/// change rarely and only through the app; the widget shows them as they came.
public struct ReadingStatisticsSnapshot: Codable, Sendable, Equatable {

    /// A day with reading time per kind in seconds and the pages read — `date` is
    /// the start of the day.
    public struct Day: Codable, Sendable, Equatable, Identifiable {
        public let date: Date
        public let book: TimeInterval
        public let manga: TimeInterval
        public let audiobook: TimeInterval
        public let pages: Int

        public var id: Date { date }
        public var total: TimeInterval { book + manga + audiobook }

        public init(
            date: Date, book: TimeInterval = 0, manga: TimeInterval = 0, audiobook: TimeInterval = 0,
            pages: Int = 0
        ) {
            self.date = date
            self.book = max(book, 0)
            self.manga = max(manga, 0)
            self.audiobook = max(audiobook, 0)
            self.pages = max(pages, 0)
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case date = "datum"
            case book = "buch"
            case manga
            case audiobook = "hoerbuch"
            case pages = "seiten"
        }
    }

    /// What the widget shows at a point in time.
    public struct Week: Sendable, Equatable {
        /// Seven days, the oldest first, the last one is today — days without data
        /// are included with 0.
        public let days: [Day]
        public let today: TimeInterval
        /// The sum of the seven days.
        public let week: TimeInterval
        /// The pages of the seven days.
        public let pages: Int
        /// The days with reading time among the seven.
        public let readingDays: Int

        /// Today's share of the week — the ring on the lock screen.
        public var fractionToday: Double { week > 0 ? min(today / week, 1) : 0 }
    }

    public let profile: String
    public let multipleProfiles: Bool
    /// The last ``retainedDays`` days, the oldest first, without gaps — empty if the
    /// profile has never read.
    public let days: [Day]
    /// Titles finished in the last 30 days.
    public let finishedMonth: Int
    /// Titles finished in the last 365 days.
    public let finishedYear: Int
    /// Started titles that are no longer visible on the start page.
    public let stalled: Int
    public let written: Date

    /// How many days the app provides.
    public static let retainedDays = 14
    /// How many the widget shows.
    public static let shown = 7

    public init(
        profile: String, multipleProfiles: Bool = false, days: [Day],
        finishedMonth: Int = 0, finishedYear: Int = 0, stalled: Int = 0, written: Date = Date()
    ) {
        self.profile = profile
        self.multipleProfiles = multipleProfiles
        self.days = Array(days.suffix(ReadingStatisticsSnapshot.retainedDays))
        self.finishedMonth = max(finishedMonth, 0)
        self.finishedYear = max(finishedYear, 0)
        self.stalled = max(stalled, 0)
        self.written = written
    }

    /// "Not read yet" — no day, nothing finished.
    public static func empty(profile: String, multipleProfiles: Bool = false) -> ReadingStatisticsSnapshot {
        ReadingStatisticsSnapshot(
            profile: profile, multipleProfiles: multipleProfiles, days: [])
    }

    public var empty: Bool { days.isEmpty }

    /// The seven days up to `now` — from the retained days what is there, otherwise 0.
    public func week(asOf now: Date, calendar: Calendar = .current) -> Week {
        let today = calendar.startOfDay(for: now)
        var seven: [Day] = []
        for daysBack in stride(from: ReadingStatisticsSnapshot.shown - 1, through: 0, by: -1) {
            guard let tag = calendar.date(byAdding: .day, value: -daysBack, to: today) else { continue }
            let present = days.first { calendar.isDate($0.date, inSameDayAs: tag) }
            seven.append(
                present.map {
                    Day(date: tag, book: $0.book, manga: $0.manga, audiobook: $0.audiobook, pages: $0.pages)
                } ?? Day(date: tag))
        }
        let todayTime = seven.last?.total ?? 0
        let sum = seven.reduce(0) { $0 + $1.total }
        let pages = seven.reduce(0) { $0 + $1.pages }
        let readingDays = seven.filter { $0.total > 0 }.count
        return Week(days: seven, today: todayTime, week: sum, pages: pages, readingDays: readingDays)
    }

    /// The next midnight after `now` — the timeline entry at which "today"
    /// drops to 0.
    public static func nextMidnight(to now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case profile = "profil"
        case multipleProfiles = "mehrereProfile"
        case days = "tage"
        case finishedMonth = "beendetMonat"
        case finishedYear = "beendetJahr"
        case stalled = "liegengeblieben"
        case written = "geschrieben"
    }
}
