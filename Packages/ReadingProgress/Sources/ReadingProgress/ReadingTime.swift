import CloudSync
import Foundation
import SourcesKit

/// A reading session as the log counts it: one title, one span of time, the reading time
/// within it (page turning and pauses already subtracted) and what was accomplished.
/// All local; none of it goes to a server.
public struct ReadingSession: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let identifier: TitleID
    public let kind: Kind
    public let startTime: Date
    public var end: Date
    /// Seconds of actual reading time.
    public var readingTime: TimeInterval
    /// Pages for comics and PDF, 0 for books and audiobooks.
    public var pages: Int
    /// How far the title progressed, as a fraction (0 … 1): the measure for books and
    /// audiobooks, in addition to the pages for comics.
    public var fraction: Double
    public var completed: Bool
    /// What the title was called when it was read, so the statistics can still name it
    /// when the account is signed out and the shelf no longer knows it. Optional because
    /// logs from before carry no name and must stay readable: `decodeIfPresent` through
    /// synthesis, no custom decoder.
    public var name: String?

    public init(
        id: UUID = UUID(), identifier: TitleID, kind: Kind, startTime: Date, end: Date,
        readingTime: TimeInterval,
        pages: Int = 0, fraction: Double = 0, completed: Bool = false, name: String? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.kind = kind
        self.startTime = startTime
        self.end = end
        self.readingTime = readingTime
        self.pages = pages
        self.fraction = fraction
        self.completed = completed
        self.name = name
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case identifier = "kennung"
        case kind = "art"
        case startTime = "beginn"
        case end = "ende"
        case readingTime = "lesezeit"
        case pages = "seiten"
        case fraction = "anteil"
        case completed = "abgeschlossen"
        case name
    }
}

/// Counts reading time from a reader's state reports, and separates reading from page
/// turning and pauses by the gap between two reports:
///
/// - **Comic/PDF:** 5 s to 5 min between two pages is reading (it used to be 8 s, but an
///   action page is done in five seconds). Faster is page turning (searching, skipping),
///   slower is a pause; neither counts.
/// - **Book:** 20 s to 10 min between two position reports.
/// - **Audiobook:** the player reports every 15 s while playing; a gap up to 45 s is
///   listening, and the gap itself is counted (not the track time, which jumps when
///   seeking). Longer is a pause.
///
/// The counter is pure arithmetic without a clock: the time arrives with every report,
/// which makes it testable. A session ends at ``finish()`` or by itself when a report
/// arrives after a long pause (audiobook: the player lives on).
public struct ReadingTimeCounter: Sendable {

    public struct Thresholds: Sendable {
        public let atLeast: TimeInterval
        public let atMost: TimeInterval

        public static func `for`(_ kind: Kind) -> Thresholds {
            switch kind {
            case .manga: Thresholds(atLeast: 5, atMost: 5 * 60)
            case .book: Thresholds(atLeast: 20, atMost: 10 * 60)
            case .audiobook, .podcast: Thresholds(atLeast: 0, atMost: 45)
            }
        }
    }

    /// Shorter does not count as a session: opening by accident is not reading.
    public static let minimumSession: TimeInterval = 30

    public let identifier: TitleID
    public let kind: Kind
    /// The title's display name; goes into every session (``ReadingSession/name``).
    public let name: String?
    private let thresholds: Thresholds
    private var session: ReadingSession?
    private var last: (time: Date, spot: ReadingState.Position)?
    private var first: ReadingState.Position?

    public init(identifier: TitleID, kind: Kind, name: String? = nil) {
        self.identifier = identifier
        self.kind = kind
        self.name = name
        self.thresholds = Thresholds.for(kind)
    }

    /// The running session as far as counted, or `nil` below the minimum duration.
    public var ongoing: ReadingSession? {
        guard let s = session, s.readingTime >= ReadingTimeCounter.minimumSession else { return nil }
        return s
    }

    /// A report from the reader. Returns a **finished** session if this report came
    /// after a long pause and the old session is therefore over.
    @discardableResult
    public mutating func report(
        _ spot: ReadingState.Position, now: Date, completed: Bool = false
    )
        -> ReadingSession?
    {
        var done: ReadingSession?
        if let last {
            let spacing = now.timeIntervalSince(last.time)
            if spacing > thresholds.atMost {
                // Pause: the old session is over, this report begins a new one.
                done = ongoing
                session = nil
                first = nil
            } else if spacing >= thresholds.atLeast, spacing > 0 {
                if session == nil {
                    session = ReadingSession(
                        identifier: identifier, kind: kind, startTime: last.time, end: now, readingTime: 0,
                        name: name)
                    first = last.spot
                }
                session?.readingTime += spacing
                session?.end = now
                session?.pages += ReadingTimeCounter.pages(from: last.spot, until: spot)
                if let first {
                    session?.fraction = max(
                        ReadingTimeCounter.fraction(spot) - ReadingTimeCounter.fraction(first), 0)
                }
            }
        }
        if completed { session?.completed = true }
        self.last = (now, spot)
        return done
    }

    /// When the reader closes: the session, if it was one.
    public mutating func finish() -> ReadingSession? {
        let s = ongoing
        session = nil
        last = nil
        first = nil
        return s
    }

    static func pages(from: ReadingState.Position, until: ReadingState.Position) -> Int {
        if case .page(let a, _) = from, case .page(let b, _) = until { return max(b - a, 0) }
        return 0
    }

    static func fraction(_ spot: ReadingState.Position) -> Double {
        switch spot {
        case .page(let n, let from): from > 0 ? Double(n) / Double(from) : 0
        case .position(_, let a), .fraction(let a): a
        case .second(let s, let from): from > 0 ? s / from : 0
        }
    }
}

/// The log of sessions: a JSON file under "Application Support", at most 5,000 entries
/// (the oldest drop). Can be switched off; off means nothing is written, and what is
/// there stays until "Delete".
///
/// **And via the profile zone in CloudKit** (formerly the iCloud key-value store per
/// profile name): each session is a `Lesesitzung` record in the profile's zone, whose
/// `recordName` is its ``ReadingSession/id``. The same session on two devices is thus the
/// same record, and updating the running audiobook session is a conflict the zone
/// resolves: **the later end wins** (``MergeRule/largerValue(_:)``). The zone's mirror is
/// the truth for the last twelve months (``ReadingTimeCloud/window``); what is older
/// stays only in the file, since the statistics show week, month, year. "Delete
/// statistics" deletes the zone's records; the other device sees them disappear and
/// deletes too.
///
/// **Transition:** on the first launch with the zone, the old key
/// `profil.<name>.lesezeit` is read once (``ReadingTimeCloud/unpack(_:)``), written to the
/// zone and removed.
@MainActor
@Observable
public final class ReadingTimeLog {

    public private(set) var sessions: [ReadingSession] = []
    private let file: URL?
    /// The profile's zone, `nil` without a profile (preview, tests).
    public let cloud: ProfileZone?
    private var observation: ObservationToken?
    /// When something was last taken from the cloud or written there, for the diagnostic
    /// line in the statistics sheet ("statistics on the phone, not on the tablet": without
    /// this line you cannot tell whether the cloud ever carried anything).
    public var cloudTraffic: Date? { cloud?.recently }

    /// What the cloud currently holds for this profile.
    public enum CloudState: Equatable, Sendable {
        /// No cloud carrier attached (preview, tests, sync off).
        case withoutCloud
        /// No iCloud account on the device; the zone stays local.
        case noAccount
        /// No session in the zone yet.
        case empty
        /// This many sessions are there, the youngest ended then.
        case sessions(Int, youngest: Date?)
    }

    /// The state from the zone's mirror; the line in the sheet says what applies now.
    public var cloudState: CloudState {
        guard let cloud, cloud.state != .withoutCloud else { return .withoutCloud }
        if cloud.state == .noAccount { return .noAccount }
        let there = cloud.allRecords(ofType: ReadingTimeLog.type)
        guard !there.isEmpty else { return .empty }
        return .sessions(there.count, youngest: there.compactMap { $0["ende"]?.time }.max())
    }

    /// Triggers the sync by hand.
    public func equalSince() {
        guard let cloud else { return }
        Task { await cloud.equalSince() }
    }

    public static let limit = 5_000
    public static let storeKey = "lesezeit"
    /// The record type in the zone.
    public nonisolated static let type = "Lesesitzung"

    /// A profile's old iCloud key (`profil.<name>.lesezeit`), now only for the transition.
    public static func cloudKey(profile name: String) -> String { "profil.\(name).lesezeit" }

    /// - Parameters:
    ///   - file: where the log lives; `nil` keeps it in memory only (tests).
    ///   - cloud: the profile's zone; `nil` in tests, previews and wherever no profile is
    ///     attached.
    ///   - legacyData: the old key in the iCloud key-value store, to be collected once
    ///     (transition).
    public init(
        file: URL? = ReadingTimeLog.defaultFileName, cloud: ProfileZone? = nil, legacyData: LegacyData? = nil
    ) {
        self.file = file
        self.cloud = cloud
        restoreFromDisk()
        guard let cloud else { return }
        cloud.rule(for: ReadingTimeLog.type, .largerValue("ende"))
        if let legacyData, let data = legacyData.data() {
            if let old = ReadingTimeCloud.unpack(data) {
                sessions = Array(ReadingTimeLog.merge(sessions, old).suffix(ReadingTimeLog.limit))
                write()
            }
            legacyData.remove()
        }
        // What the file has and the zone does not (the state before the zone, or a freshly
        // bound zone): up it goes, only the window, since older data needs no device.
        let cutoff = Date().addingTimeInterval(-ReadingTimeCloud.window)
        let there = Set(cloud.allRecords(ofType: ReadingTimeLog.type).map(\.name))
        for s in sessions where s.end >= cutoff && !there.contains(s.id.uuidString) {
            cloud.write(ReadingTimeLog.makeRecord(s))
        }
        adopt(cloud.allRecords(ofType: ReadingTimeLog.type))
        observation = cloud.observe(ReadingTimeLog.type) { [weak self] records in self?.adopt(records) }
    }

    public static var defaultFileName: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "lesezeit.json")
    }

    /// Adds a session, or replaces it if the same one is already there (an audiobook
    /// reports its running session every few minutes so a crash does not swallow the
    /// whole drive).
    public func save(_ session: ReadingSession) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
            if sessions.count > ReadingTimeLog.limit {
                sessions.removeFirst(sessions.count - ReadingTimeLog.limit)
            }
        }
        write()
        cloud?.write(ReadingTimeLog.makeRecord(session))
    }

    /// Deletes here and in the zone; the other device follows when it sees the records
    /// disappear.
    public func erase() {
        sessions = []
        write()
        cloud?.eraseAll(type: ReadingTimeLog.type)
    }

    /// The union of two states by session identifier: what is only on one side is added;
    /// what is on both counts in the version with the later end, or with the longer
    /// reading time if the end is equal. Sorted by end so the upper limit (the oldest
    /// drop) hits the same ones on both devices.
    public static func merge(_ own: [ReadingSession], _ foreign: [ReadingSession]) -> [ReadingSession] {
        var byID: [UUID: ReadingSession] = [:]
        for s in own + foreign {
            if let existing = byID[s.id], (existing.end, existing.readingTime) >= (s.end, s.readingTime) {
                continue
            }
            byID[s.id] = s
        }
        return byID.values.sorted { ($0.end, $0.id.uuidString) < ($1.end, $1.id.uuidString) }
    }

    /// The zone's state is the truth within the window: what is there counts; what the
    /// file has within the window and the zone no longer has was deleted elsewhere. Older
    /// data stays as it is.
    func adopt(_ records: [CloudRecord]) {
        let foreign = records.compactMap(ReadingTimeLog.session(from:))
        let cutoff = Date().addingTimeInterval(-ReadingTimeCloud.window)
        let there = Set(foreign.map(\.id))
        let old = sessions.filter { $0.end < cutoff && !there.contains($0.id) }
        let merged = ReadingTimeLog.merge(old, foreign)
        guard merged != sessions else { return }
        sessions = Array(merged.suffix(ReadingTimeLog.limit))
        write()
    }

    // MARK: - Record <-> session

    nonisolated static func makeRecord(_ s: ReadingSession) -> CloudRecord {
        var fields: [String: FieldValue] = [
            "anbieter": .text(s.identifier.source.provider.rawValue),
            "server": .text(s.identifier.source.server),
            "titel": .text(s.identifier.id),
            "art": .text(s.kind.rawValue),
            "beginn": .time(s.startTime),
            "ende": .time(s.end),
            "lesezeit": .decimalNumber(s.readingTime),
            "seiten": .integer(s.pages),
            "anteil": .decimalNumber(s.fraction),
            "abgeschlossen": .truth(s.completed),
        ]
        if let name = s.name { fields["name"] = .text(name) }
        return CloudRecord(type: type, name: s.id.uuidString, fields: fields)
    }

    nonisolated static func session(from record: CloudRecord) -> ReadingSession? {
        guard let id = UUID(uuidString: record.name),
            let provider = record["anbieter"]?.text.flatMap(Provider.init(rawValue:)),
            let server = record["server"]?.text, let title = record["titel"]?.text,
            let kind = record["art"]?.text.flatMap(Kind.init(rawValue:)),
            let startTime = record["beginn"]?.time, let end = record["ende"]?.time
        else { return nil }
        return ReadingSession(
            id: id,
            identifier: TitleID(source: SourceID(provider: provider, server: server), id: title),
            kind: kind, startTime: startTime, end: end, readingTime: record["lesezeit"]?.decimalNumber ?? 0,
            pages: record["seiten"]?.integer ?? 0, fraction: record["anteil"]?.decimalNumber ?? 0,
            completed: record["abgeschlossen"]?.truth ?? false, name: record["name"]?.text)
    }

    private func restoreFromDisk() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? decoder.decode([ReadingSession].self, from: data)) ?? []
    }

    private func write() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// The numbers for the statistics sheet, computed from the sessions for a period:
/// reading time in total and per kind, pages, finished titles, daily bars, streak (days
/// in a row up to today), and the same numbers **per title** (``titleValues``), so that
/// "7 h 10 min" becomes a path to the book.
public struct ReadingStatistics: Sendable, Hashable {

    /// A title in the statistics: what was read of it in the period, and the pace derived
    /// from that. The name comes from the youngest session that carries one, for titles
    /// the shelf no longer knows.
    public struct TitleValue: Sendable, Hashable, Identifiable {
        public let identifier: TitleID
        public let kind: Kind
        public let name: String?
        public let readingTime: TimeInterval
        public let sessions: Int
        public let pages: Int
        /// The fraction read in the period: the sum of the sessions, not the current state.
        public let fraction: Double
        /// Whether a session in the period finished the title.
        public let completed: Bool
        public let recently: Date
        public var id: TitleID { identifier }

        /// Below five minutes there is no pace: "about 900 h left" from a minute of
        /// page turning helps nobody.
        public static let minimumTime: TimeInterval = 5 * 60

        /// Pages per hour: manga only, and only if pages were counted.
        public var pagesPerHour: Double? {
            guard kind == .manga, pages > 0, readingTime >= TitleValue.minimumTime else { return nil }
            return Double(pages) / (readingTime / 3600)
        }

        /// Fraction per hour: the measure for books and audiobooks, the substitute for
        /// manga when pages are missing.
        public var fractionPerHour: Double? {
            guard fraction > 0.001, readingTime >= TitleValue.minimumTime else { return nil }
            return fraction / (readingTime / 3600)
        }

        /// "About … left", from the current state (0 … 1) and the pace; for manga via the
        /// pages if the shelf knows the length. `nil` without a pace or if the title is
        /// finished.
        public func remainingTime(state: Double, pagesTotal: Int? = nil) -> TimeInterval? {
            let unresolved = 1 - min(max(state, 0), 1)
            guard unresolved > 0 else { return nil }
            if let pagesTotal, pagesTotal > 0, let pace = pagesPerHour {
                return unresolved * Double(pagesTotal) / pace * 3600
            }
            guard let pace = fractionPerHour else { return nil }
            return unresolved / pace * 3600
        }
    }

    public enum Period: Sendable, Hashable, CaseIterable {
        case week, month, year, total
    }

    public struct Day: Sendable, Hashable, Identifiable {
        public let date: Date
        public let readingTime: TimeInterval
        public var id: Date { date }

        public init(date: Date, readingTime: TimeInterval) {
            self.date = date
            self.readingTime = readingTime
        }
    }

    public let readingTime: TimeInterval
    public let perKind: [Kind: TimeInterval]
    public let pages: Int
    public let sessions: Int
    public let completed: Int
    /// Reading time per day in the period, without gaps (0 for days without), oldest first.
    public let days: [Day]
    /// Days in a row with reading, up to today or yesterday.
    public let series: Int
    /// The longest session: "in one go".
    public let longest: TimeInterval
    public let title: Set<TitleID>
    /// Per title in the period, most reading time first.
    public let titleValues: [TitleValue]

    public init(
        _ sessions: [ReadingSession], period: Period, now: Date = Date(), calendar: Calendar = .current
    ) {
        let today = calendar.startOfDay(for: now)
        let start: Date? =
            switch period {
            case .week: calendar.date(byAdding: .day, value: -6, to: today)
            case .month: calendar.date(byAdding: .day, value: -29, to: today)
            case .year: calendar.date(byAdding: .day, value: -364, to: today)
            case .total: nil
            }
        let included = sessions.filter { s in
            (start.map { $0 <= s.end } ?? true) && s.end <= now.addingTimeInterval(60)
        }
        readingTime = included.reduce(0) { $0 + $1.readingTime }
        var kinds: [Kind: TimeInterval] = [:]
        for s in included { kinds[s.kind, default: 0] += s.readingTime }
        perKind = kinds
        pages = included.reduce(0) { $0 + $1.pages }
        self.sessions = included.count
        completed = Set(included.filter(\.completed).map(\.identifier)).count
        longest = included.map(\.readingTime).max() ?? 0
        title = Set(included.map(\.identifier))
        titleValues = ReadingStatistics.titleValues(included)

        var perDay: [Date: TimeInterval] = [:]
        for s in included { perDay[calendar.startOfDay(for: s.end), default: 0] += s.readingTime }
        let firstDay = start ?? perDay.keys.min() ?? today
        var days: [Day] = []
        var day = firstDay
        while day <= today {
            days.append(Day(date: day, readingTime: perDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        self.days = days

        // The streak counts over all sessions, not just the period: it is a run.
        var allDays = Set(sessions.map { calendar.startOfDay(for: $0.end) })
        var series = 0
        var probe = today
        if !allDays.contains(today), let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            probe = yesterday
        }
        while allDays.remove(probe) != nil {
            series += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: probe) else { break }
            probe = before
        }
        self.series = series
    }

    public func titleValue(_ identifier: TitleID) -> TitleValue? {
        titleValues.first { $0.identifier == identifier }
    }

    /// The titles finished in the period: the "finished" figure as a list.
    public var finishedOnes: [TitleValue] { titleValues.filter(\.completed) }

    /// The titles of one kind: the "per kind" row as a list; `nil` means all.
    public func titleValues(_ kind: Kind?) -> [TitleValue] {
        kind.map { a in titleValues.filter { $0.kind == a } } ?? titleValues
    }

    static func titleValues(_ sessions: [ReadingSession]) -> [TitleValue] {
        var clusters: [TitleID: [ReadingSession]] = [:]
        for s in sessions { clusters[s.identifier, default: []].append(s) }
        return clusters.map { identifier, own -> TitleValue in
            let byEnd = own.sorted { $0.end < $1.end }
            return TitleValue(
                identifier: identifier, kind: byEnd.last!.kind,
                name: byEnd.last { $0.name != nil }?.name,
                readingTime: own.reduce(0) { $0 + $1.readingTime }, sessions: own.count,
                pages: own.reduce(0) { $0 + $1.pages },
                fraction: min(own.reduce(0) { $0 + $1.fraction }, 1),
                completed: own.contains(where: \.completed), recently: byEnd.last!.end)
        }
        .sorted { a, b in
            if a.readingTime != b.readingTime { return a.readingTime > b.readingTime }
            return a.recently > b.recently
        }
    }
}
