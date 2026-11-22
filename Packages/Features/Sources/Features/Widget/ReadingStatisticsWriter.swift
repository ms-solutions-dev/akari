import Bedrock
import Foundation
import ReadingProgress
import SourcesKit
import WidgetBridge

#if canImport(WidgetKit)
    import WidgetKit
#endif

extension ReadingStatisticsSnapshot {

    /// The snapshot from the log: the last fourteen days with reading time per kind
    /// and pages (sessions count to the day they ended, as in the statistics sheet), the
    /// finished titles of the month and year segments, and the number of stalled
    /// titles from the shelf. Without a session the empty snapshot (even if something
    /// is stalled: without reading time there are no statistics, and the sheet says
    /// the same).
    static func from(
        _ sessions: [ReadingSession], stalled: Int = 0, profile: String, multipleProfiles: Bool,
        now: Date = Date(), calendar: Calendar = .current
    ) -> ReadingStatisticsSnapshot {
        guard !sessions.isEmpty else { return .empty(profile: profile, multipleProfiles: multipleProfiles) }
        let today = calendar.startOfDay(for: now)
        var perDay: [Date: (book: TimeInterval, manga: TimeInterval, audiobook: TimeInterval, pages: Int)] =
            [:]
        for s in sessions where s.end <= now.addingTimeInterval(60) {
            let day = calendar.startOfDay(for: s.end)
            var value = perDay[day] ?? (0, 0, 0, 0)
            switch s.kind {
            case .book: value.book += s.readingTime
            case .manga: value.manga += s.readingTime
            case .audiobook, .podcast: value.audiobook += s.readingTime
            }
            value.pages += s.pages
            perDay[day] = value
        }
        var days: [Day] = []
        for back in stride(from: ReadingStatisticsSnapshot.retainedDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let value = perDay[day] ?? (0, 0, 0, 0)
            days.append(
                Day(
                    date: day, book: value.book, manga: value.manga, audiobook: value.audiobook,
                    pages: value.pages))
        }
        let month = ReadingStatistics(sessions, period: .month, now: now, calendar: calendar)
        let year = ReadingStatistics(sessions, period: .year, now: now, calendar: calendar)
        return ReadingStatisticsSnapshot(
            profile: profile, multipleProfiles: multipleProfiles, days: days,
            finishedMonth: month.completed, finishedYear: year.completed,
            stalled: stalled,
            written: now)
    }
}

/// Writes the "reading statistics" snapshot into the app group and wakes the widget,
/// after every session that goes into the log (also the running one every two minutes), at
/// launch, on profile switch and when the stalled titles change: the watcher
/// hangs on `ReadingTimeLog.sessions` and on the shelf. Bundled like the other writers;
/// what stays the same is not written again.
@MainActor
final class ReadingStatisticsWriter {

    static let waitTime: Duration = .seconds(2)

    private let folder: URL?
    private var planned: Task<Void, Never>?
    private var pending: Job?
    private var recently: ReadingStatisticsSnapshot?

    struct Job: Equatable {
        let sessions: [ReadingSession]
        let stalled: Int
        let profile: String
        let multipleProfiles: Bool
    }

    init(folder: URL? = SnapshotStore.statisticsFolder()) {
        self.folder = folder
    }

    func schedule(_ job: Job) {
        pending = job
        planned?.cancel()
        planned = Task { [weak self] in
            try? await Task.sleep(for: ReadingStatisticsWriter.waitTime)
            guard !Task.isCancelled else { return }
            self?.planned = nil
            self?.writePending()
        }
    }

    func immediately() {
        planned?.cancel()
        planned = nil
        writePending()
    }

    private func writePending() {
        guard let job = pending else { return }
        pending = nil
        write(job)
    }

    private func write(_ job: Job) {
        guard let folder else { return }
        let snapshot = ReadingStatisticsSnapshot.from(
            job.sessions, stalled: job.stalled, profile: job.profile,
            multipleProfiles: job.multipleProfiles)
        if let recently, recently.days == snapshot.days, recently.profile == snapshot.profile,
            recently.multipleProfiles == snapshot.multipleProfiles,
            recently.finishedMonth == snapshot.finishedMonth,
            recently.finishedYear == snapshot.finishedYear,
            recently.stalled == snapshot.stalled
        {
            return
        }
        do {
            try SnapshotStore.writeStatistics(snapshot, in: folder)
            recently = snapshot
            let today = Int((snapshot.days.last?.total ?? 0) / 60)
            Diagnostics.step(
                "Widget reading statistics: \(today) min today, "
                    + "\(snapshot.stalled) stalled", since: nil, area: "Widget")
            #if canImport(WidgetKit)
                WidgetCenter.shared.reloadTimelines(ofKind: SnapshotStore.statisticsKind)
            #endif
        } catch {
            Diagnostics.network.error(
                "Widget reading statistics snapshot not written: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
