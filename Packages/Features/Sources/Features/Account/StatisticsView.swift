import Charts
import CloudSync
import DesignSystem
import Library
import ReadingProgress
import SourcesKit
import SwiftUI

/// The statistics sheet: reading time, pages, finished titles, reading days, per period;
/// below them the day bars and the time per kind. Computed from the
/// ``ReadingProgress/ReadingTimeLog``, which separates reading from page turning and
/// pauses: whoever flips pages for an hour has not read. Can be switched off and
/// deleted; synced between devices via the profile zone in CloudKit.
///
/// With a way to the title: "Finished", the rows per kind and "Titles" are links into the
/// ``StatisticsTitleList``, and below sits **Stalled**, what is started but no longer
/// visible on Start (``Library/Shelf/stalled``).
struct StatisticsView: View {

    @Environment(ReadingTimeLog.self) private var log
    @Environment(LibraryService.self) private var inventory
    @Environment(AppCore.self) private var core
    @Environment(\.theme) private var theme
    @AppStorage(PositionReporter.recordKey) private var record = true
    @State private var period: ReadingStatistics.Period = .week
    @State private var deleteQuestion = false

    /// "iCloud: 312 sessions, latest 20 Sep, 00:05, as of 00:09, shared by ..." or why
    /// nothing is there ("no iCloud account", "unreachable, 3 changes waiting"). From
    /// the zone (``CloudSync/ProfileZone``), no longer from the key store.
    private var cloudRow: String {
        var extra: [String] = []
        if let zone = log.cloud, zone.state != .withoutCloud {
            switch zone.state {
            case .synced(let when):
                extra.append(
                    Phrase.from("statistics.cloud.recently", when.formatted(date: .omitted, time: .shortened))
                )
            case .unreachable: extra.append(Phrase.from("cloud.state.unreachable"))
            case .neverSynced, .unbound: extra.append(Phrase.from("cloud.state.never"))
            case .lost: extra.append(Phrase.from("cloud.lost"))
            case .rejected(let reason): extra.append(Phrase.from("cloud.state.rejected", reason))
            case .withoutCloud, .noAccount: break
            }
            if zone.pending > 0 { extra.append(Phrase.from("cloud.state.wait", zone.pending)) }
            if let from = zone.sharedBy { extra.append(Phrase.from("profile.sharedBy", from)) }
        }
        let suffix = extra.map { " · " + $0 }.joined()
        switch log.cloudState {
        case .withoutCloud: return Phrase.from("statistics.cloud.without")
        case .noAccount: return Phrase.from("statistics.cloud.noAccount")
        case .empty: return Phrase.from("statistics.cloud.empty") + suffix
        case .sessions(let integer, let youngest):
            let when = youngest?.formatted(date: .numeric, time: .shortened) ?? "–"
            return Phrase.from("statistics.cloud.sessions", integer, when) + suffix
        }
    }

    var body: some View {
        let statistics = ReadingStatistics(log.sessions, period: period)
        List {
            Section {
                PeriodPicker(period: $period)
            }

            if log.sessions.isEmpty {
                Section {
                    Text(app: record ? "statistics.empty" : "statistics.off")
                        .font(.subheadline)
                        .foregroundStyle(ColorTheme.muted.color)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        KeyFigure(
                            value: StatisticsView.time(statistics.readingTime),
                            name: Text(app: "statistics.readingTime"))
                        // Books measure progress as a share, not in pages: instead of
                        // "0 pages" next to "3 min", show the sessions.
                        if statistics.pages > 0 {
                            KeyFigure(
                                value: Formats.integer(statistics.pages), name: Text(app: "statistics.pages"))
                        } else {
                            KeyFigure(
                                value: Formats.integer(statistics.sessions),
                                name: Text(app: "statistics.sessions.name"))
                        }
                        KeyFigure(
                            value: Formats.integer(statistics.completed),
                            name: Text(app: "statistics.finished"),
                            arrow: true
                        )
                        .overlay {
                            NavigationLink(value: StatisticsTarget.finished(period)) { Color.clear }
                                .opacity(0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isLink)
                        // Reading days instead of "days in a row": no streaks.
                        KeyFigure(
                            value: Formats.integer(statistics.days.filter { $0.readingTime > 0 }.count),
                            name: Text(app: "statistics.readingDays"))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    DayBar(days: statistics.days, period: period)
                        .frame(height: 160)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } header: {
                    Text(app: "statistics.history")
                }

                Section {
                    ForEach(Kind.allCases, id: \.self) { kind in
                        if let time = statistics.perKind[kind], time > 0 {
                            NavigationLink(value: StatisticsTarget.title(period, kind)) {
                                LabeledContent {
                                    Text(verbatim: StatisticsView.time(time)).monospacedDigit()
                                } label: {
                                    Label {
                                        Text(appKey: kind.segmentKey)
                                    } icon: {
                                        Image(systemName: Cover.glyph(kind))
                                    }
                                }
                            }
                        }
                    }
                    LabeledContent {
                        Text(verbatim: StatisticsView.time(statistics.longest)).monospacedDigit()
                    } label: {
                        Text(app: "statistics.longest")
                    }
                    NavigationLink(value: StatisticsTarget.title(period, nil)) {
                        LabeledContent {
                            Text(verbatim: Formats.integer(statistics.title.count)).monospacedDigit()
                        } label: {
                            Text(app: "statistics.title")
                        }
                    }
                } header: {
                    Text(app: "statistics.perKind")
                }
            }

            let stalledTitles = inventory.shelf.stalled
            if !stalledTitles.isEmpty {
                Section {
                    ForEach(stalledTitles.prefix(StatisticsView.stalledShown)) { l in
                        EntryRow(
                            entry: .title(l.title),
                            secondaryLine: Text(verbatim: StatisticsView.stalledRow(l)),
                            withKind: true)
                    }
                    if stalledTitles.count > StatisticsView.stalledShown {
                        NavigationLink(value: Target.stalled) {
                            Text(verbatim: Phrase.from("statistics.stalled.all", stalledTitles.count))
                        }
                    }
                } header: {
                    Text(app: "statistics.stalled")
                } footer: {
                    Text(app: "statistics.stalled.hint")
                }
            }

            Section {
                Toggle(isOn: $record) { Text(app: "statistics.capture") }
                if !log.sessions.isEmpty {
                    Button(role: .destructive) {
                        deleteQuestion = true
                    } label: {
                        Text(app: "statistics.delete")
                    }
                }
            } footer: {
                Text(app: "statistics.hint")
            }

            // The diagnostics row: says what the cloud holds for this profile, otherwise
            // "the statistics are missing on the tablet" cannot be told apart from "iCloud
            // off". "Sync now" fetches and writes by hand.
            Section {
                Button {
                    log.equalSince()
                } label: {
                    Text(app: "statistics.cloud.sync")
                }
                .disabled(
                    log.cloudState == .withoutCloud || log.cloudState == .noAccount || log.cloud?.zone == nil)
            } footer: {
                Text(cloudRow)
            }
        }
        .scrollContentBackground(.hidden)
        .paper()
        .navigationTitle(Text(app: "statistics.title.sheet"))
        .toolbarTitleDisplayMode(.inline)
        .onAppear { core.sameCloudSince() }
        .confirmationDialog(
            Text(app: "statistics.delete.question"), isPresented: $deleteQuestion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                log.erase()
            } label: {
                Text(app: "statistics.delete")
            }
        }
    }

    /// How many stalled titles the sheet shows itself; the rest sits behind "All".
    static let stalledShown = 5

    /// "Volume 47, p. 63/205, last 3 weeks ago": the state as on Start, plus when it
    /// was last read, which is the question for stalled titles. With a number ("1 month
    /// ago"), not with names; "last last month" stumbled.
    static func stalledRow(_ l: Shelf.Reading) -> String {
        let her = l.state.timestamp.formatted(.relative(presentation: .numeric))
        return StartView.statusLine(l) + " · " + Phrase.from("statistics.recently", her)
    }

    static func lookupKey(_ z: ReadingStatistics.Period) -> String {
        switch z {
        case .week: "statistics.week"
        case .month: "statistics.month"
        case .year: "statistics.year"
        case .total: "statistics.total"
        }
    }

    /// "2 h 15 min", "35 min", "0 min": short, as one says it; the system's "hr, min"
    /// reads like a form.
    static func time(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60, minutes % 60 == 0 { return Phrase.from("statistics.time.onlyH", minutes / 60) }
        return minutes >= 60
            ? Phrase.from("statistics.time.h", minutes / 60, minutes % 60)
            : Phrase.from("statistics.time.min", minutes)
    }
}

/// A large number with a name below, the four tiles at the top. With `arrow` it carries
/// a chevron at the top right: the tile is a link, and that should be visible. The
/// `NavigationLink` lies invisibly **over** the tile, not around it; as a link's label
/// it would get the system chevron beside it in the list and become narrower.
struct KeyFigure: View {

    let value: String
    let name: Text
    var arrow = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value)
                .font(Typography.title(.title2))
                .monospacedDigit()
                .foregroundStyle(ColorTheme.typography.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            name
                .font(.footnote)
                .foregroundStyle(ColorTheme.muted.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if arrow {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ColorTheme.muted.color)
                    .padding(12)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The reading time per day as bars, in minutes, in the theme accent; for the year and
/// "Total" bundled by weeks, otherwise there would be 365 strokes.
struct DayBar: View {

    let days: [ReadingStatistics.Day]
    let period: ReadingStatistics.Period
    @Environment(\.theme) private var theme

    private var bundle: [ReadingStatistics.Day] {
        guard period == .year || period == .total, days.count > 60 else { return days }
        let calendar = Calendar.current
        var weeks: [Date: TimeInterval] = [:]
        for t in days {
            let week = calendar.dateInterval(of: .weekOfYear, for: t.date)?.start ?? t.date
            weeks[week, default: 0] += t.readingTime
        }
        return weeks.keys.sorted().map { ReadingStatistics.Day(date: $0, readingTime: weeks[$0]!) }
    }

    var body: some View {
        let data = bundle
        let calendarUnit: Calendar.Component = data.count == days.count ? .day : .weekOfYear
        Chart(data) { day in
            BarMark(
                x: .value("Tag", day.date, unit: calendarUnit),
                y: .value("Minuten", day.readingTime / 60)
            )
            .foregroundStyle(theme.accent.color)
            .cornerRadius(3)
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(theme.hairline.color)
                AxisValueLabel {
                    if let m = value.as(Double.self) {
                        Text(verbatim: Phrase.from("statistics.minutes.short", Int(m)))
                            .font(.caption2)
                            .foregroundStyle(ColorTheme.muted.color)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: period == .week ? 7 : 4)) { value in
                AxisValueLabel(
                    format: period == .week
                        ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated)
                )
                .font(.caption2)
                .foregroundStyle(ColorTheme.muted.color)
            }
        }
        .accessibilityLabel(Text(app: "statistics.history"))
        .accessibilityValue(Text(verbatim: StatisticsView.time(data.reduce(0) { $0 + $1.readingTime })))
    }
}
