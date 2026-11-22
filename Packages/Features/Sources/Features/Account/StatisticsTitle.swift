import DesignSystem
import Library
import ReadingProgress
import SourcesKit
import SwiftUI

/// The sheets behind the statistics sheet: the titles of a period (all, of one kind, or only
/// the finished ones) and the sheet for a single title. A value so that a probe can name
/// them; resolved in the account sheet's stack.
enum StatisticsTarget: Hashable {
    case title(ReadingStatistics.Period, Kind?)
    case finished(ReadingStatistics.Period)
    case single(TitleID)
}

extension View {

    /// The sheets behind the statistics targets, in the account sheet's stack next to
    /// ``targets()``, because a title leads from here to the regular title detail.
    func statisticsTargets() -> some View {
        navigationDestination(for: StatisticsTarget.self) { target in
            switch target {
            case .title(let period, let kind): StatisticsTitleList(period: period, kind: kind)
            case .finished(let period): StatisticsTitleList(period: period, kind: nil, onlyFinished: true)
            case .single(let identifier): StatisticsTitleView(identifier: identifier)
            }
        }
    }
}

/// The list of titles read in a period, most reading time first. This turns the
/// numbers into books. The period segment comes along and stays switchable; a tap
/// leads to the title detail and from there to "Continue reading", the info button (or a
/// long press) to the title's sheet with pace and remaining time.
struct StatisticsTitleList: View {

    let kind: Kind?
    var onlyFinished = false

    @Environment(ReadingTimeLog.self) private var log
    @State private var period: ReadingStatistics.Period
    /// The title whose sheet the info button opens, as a value rather than a second
    /// `NavigationLink` in the row: with two links in a list row, a tap on the
    /// row always opened the second one.
    @State private var details: TitleID?

    init(period: ReadingStatistics.Period, kind: Kind?, onlyFinished: Bool = false) {
        self.kind = kind
        self.onlyFinished = onlyFinished
        _period = State(initialValue: period)
    }

    var body: some View {
        let statistics = ReadingStatistics(log.sessions, period: period)
        let values = onlyFinished ? statistics.finishedOnes : statistics.titleValues(kind)
        List {
            Section {
                PeriodPicker(period: $period)
            }
            if values.isEmpty {
                Section {
                    Text(app: "statistics.title.empty")
                        .font(.subheadline)
                        .foregroundStyle(ColorTheme.muted.color)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(values) { value in
                        StatisticsTitleRow(value: value, details: $details)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paper()
        .navigationDestination(item: $details) { identifier in StatisticsTitleView(identifier: identifier) }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
    }

    private var title: Text {
        if onlyFinished { return Text(app: "statistics.finished") }
        return kind.map { Text(appKey: $0.segmentKey) } ?? Text(app: "statistics.title")
    }
}

/// The period segment, shared by the statistics sheet and the title list.
struct PeriodPicker: View {

    @Binding var period: ReadingStatistics.Period

    var body: some View {
        Picker(selection: $period) {
            ForEach(ReadingStatistics.Period.allCases, id: \.self) { z in
                Text(appKey: StatisticsView.lookupKey(z)).tag(z)
            }
        } label: {
            Text(app: "statistics.period")
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

/// A row of the title list: cover, name, below it "3 h 20 min · 5 sessions" and
/// "p. 63/205 · 6 days ago". Two lines, because both in one ended in a truncated
/// "4 sessio...". If the shelf knows the title (account signed in), the row leads
/// to the title detail; otherwise it carries the name from the session, or "No longer
/// in the library", and leads to the title's sheet, since there would be no detail.
///
/// **One link per row, invisible over cover and text**, without the list's chevron,
/// because the info button (Apple's detail disclosure) already sits on the right and with
/// both the sublines wrapped. The info button is a button, not a second link: with two
/// links in a list row, a tap on the row always opened the second one; the button opens
/// the sheet through the list's `details`.
struct StatisticsTitleRow: View {

    let value: ReadingStatistics.TitleValue
    @Binding var details: TitleID?

    @Environment(LibraryService.self) private var inventory

    var body: some View {
        let title = inventory.title(value.identifier)
        let state = inventory.readingState(value.identifier)
        HStack(spacing: 4) {
            content(title: title, state: state)
                .contentShape(Rectangle())
                .overlay {
                    if title != nil {
                        NavigationLink(value: Target.title(value.identifier)) { Color.clear }
                            .buttonStyle(.plain).opacity(0)
                    } else {
                        NavigationLink(value: StatisticsTarget.single(value.identifier)) { Color.clear }
                            .buttonStyle(.plain).opacity(0)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isLink)
            if title != nil {
                Button {
                    details = value.identifier
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(ColorTheme.muted.color)
                        .frame(minWidth: 36, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(app: "statistics.details"))
            }
        }
        .contextMenu {
            if title != nil {
                Button {
                    details = value.identifier
                } label: {
                    Label(app: "statistics.details", systemImage: "chart.bar")
                }
            }
        }
    }

    private func content(title: Title?, state: ReadingState?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let title {
                Cover(title, width: 44)
            } else {
                Cover(nil, source: value.identifier.source, kind: value.kind, width: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let title {
                        Text(verbatim: Display(title, inBookSeries: false).name)
                    } else {
                        value.name.map { Text(verbatim: $0) } ?? Text(app: "statistics.noLonger")
                    }
                }
                .font(Typography.name(.body))
                .fontWeight(state?.started == true ? .semibold : .medium)
                .foregroundStyle(ColorTheme.typography.color)
                .lineLimit(2)
                Text(verbatim: StatisticsTitleRow.timeRow(value))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
                Text(verbatim: StatisticsTitleRow.statusLine(value, state: state, onShelf: title != nil))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
            }
            Spacer(minLength: 0)
        }
    }

    /// "3 h 20 min · 5 sessions". For manga the pages are added, short as in the status
    /// ("240 p."), otherwise the row wraps.
    static func timeRow(_ value: ReadingStatistics.TitleValue) -> String {
        var share = [
            StatisticsView.time(value.readingTime), Phrase.from("statistics.sessions", value.sessions),
        ]
        if value.kind == .manga, value.pages > 0 {
            share.append(Phrase.from("statistics.pages.short", value.pages))
        }
        return share.joined(separator: " · ")
    }

    /// "p. 63/205 · 6 days ago": the status from the shelf if it knows it, otherwise the
    /// share read according to the sessions; without a shelf it says the title is no
    /// longer in the library.
    static func statusLine(
        _ value: ReadingStatistics.TitleValue, state: ReadingState?, onShelf: Bool
    ) -> String {
        var share: [String] = []
        if let state {
            share.append(Formats.short(state))
        } else if !onShelf {
            share.append(Phrase.from("statistics.noLonger"))
        } else if value.fraction >= 0.01 {
            share.append(Formats.percent(value.fraction))
        }
        share.append(Formats.her(value.recently))
        return share.joined(separator: " · ")
    }
}

/// The sheet for a title: cover and status, the four all-time numbers, the
/// sessions as day bars, the pace and "about 4 h left", and the button that
/// closes the loop: continue reading. The pace is pages per hour for manga,
/// share per hour otherwise; the remaining time is computed from the shelf's current status.
struct StatisticsTitleView: View {

    let identifier: TitleID

    @Environment(ReadingTimeLog.self) private var log
    @Environment(LibraryService.self) private var inventory
    @Environment(ReadCall.self) private var reader
    @Environment(\.dynamicTypeSize) private var fontSize

    var body: some View {
        let own = log.sessions.filter { $0.identifier == identifier }
        let total = ReadingStatistics(own, period: .total)
        let value = total.titleValue(identifier)
        let title = inventory.title(identifier)
        let state = inventory.readingState(identifier)
        List {
            Section {
                header(title: title, value: value, state: state)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if let value {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        KeyFigure(
                            value: StatisticsView.time(value.readingTime),
                            name: Text(app: "statistics.totalTime"))
                        KeyFigure(
                            value: Formats.integer(value.sessions),
                            name: Text(app: "statistics.sessions.name"))
                        if value.kind == .manga {
                            KeyFigure(
                                value: Formats.integer(value.pages), name: Text(app: "statistics.pages"))
                        } else {
                            KeyFigure(
                                value: Formats.percent(value.fraction), name: Text(app: "statistics.read"))
                        }
                        KeyFigure(
                            value: Formats.her(value.recently), name: Text(app: "statistics.recently.name"))
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    DayBar(days: total.days, period: .total)
                        .frame(height: 160)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } header: {
                    Text(app: "statistics.history")
                }
                if let tempo = StatisticsTitleView.tempo(value) {
                    Section {
                        LabeledContent {
                            Text(verbatim: tempo).monospacedDigit()
                        } label: {
                            Text(app: "statistics.tempo")
                        }
                        if let remainder = StatisticsTitleView.remainder(value, state: state, title: title) {
                            LabeledContent {
                                Text(verbatim: remainder).monospacedDigit()
                            } label: {
                                Text(app: "statistics.remainder.name")
                            }
                        }
                    } footer: {
                        Text(app: "statistics.tempo.hint")
                    }
                }
            }
            if let title {
                Section {
                    Button {
                        reader.open(title)
                    } label: {
                        Text(appKey: StatisticsTitleView.buttonKey(title, state: state))
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.primary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    NavigationLink(value: Target.title(identifier)) {
                        Label(app: "statistics.toTitle", systemImage: "book")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paper()
        .navigationTitle(
            title.map { Text(verbatim: Display($0, inBookSeries: false).name) }
                ?? Text(app: "statistics.title.sheet")
        )
        .toolbarTitleDisplayMode(.inline)
    }

    /// Cover on the left, next to it badge, name and status; without a shelf it says
    /// the title is no longer in the library.
    @ViewBuilder
    private func header(
        title: Title?, value: ReadingStatistics.TitleValue?, state: ReadingState?
    ) -> some View {
        let kind = title?.kind ?? value?.kind ?? .book
        let arrangement =
            fontSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        arrangement {
            if let title {
                Cover(title, width: 88)
            } else {
                Cover(nil, source: identifier.source, kind: kind, width: 88)
            }
            VStack(alignment: .leading, spacing: 6) {
                Badge(Text(appKey: kind.lookupKey))
                Text(verbatim: title.map { Display($0, inBookSeries: false).name } ?? value?.name ?? "")
                    .font(Typography.title(.title3))
                    .foregroundStyle(ColorTheme.typography.color)
                    .lineLimit(3)
                if let state {
                    ProgressBar(fraction: state.fraction, text: Text(verbatim: Formats.long(state)))
                } else if title == nil {
                    Text(app: "statistics.noLonger")
                        .font(.subheadline)
                        .foregroundStyle(ColorTheme.muted.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "38 pages per hour" for manga, "12 % per hour" otherwise; `nil` under five
    /// minutes of reading time.
    static func tempo(_ value: ReadingStatistics.TitleValue) -> String? {
        if let pages = value.pagesPerHour {
            return Phrase.from("statistics.tempo.pages", Int(pages.rounded()))
        }
        if let fraction = value.fractionPerHour {
            return Phrase.from("statistics.tempo.share", Int((fraction * 100).rounded()))
        }
        return nil
    }

    /// "4 h 30 min" after "About"; from the shelf's status, for manga from the page count.
    static func remainder(
        _ value: ReadingStatistics.TitleValue, state: ReadingState?, title: Title?
    ) -> String? {
        guard let state, !state.completed else { return nil }
        let pages: Int? = if case .pages(let n) = title?.scope { n } else { nil }
        return value.remainingTime(state: state.fraction, pagesTotal: pages).map(StatisticsTitleView.about)
    }

    /// "4 h", "4 h 30 min", "25 min", rounded the way people say it: under an hour
    /// to five minutes, above that to the half hour.
    static func about(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return StatisticsView.time(Double(max((minutes + 2) / 5 * 5, 5)) * 60) }
        return StatisticsView.time(Double((minutes + 15) / 30 * 30) * 60)
    }

    /// Continue reading/listening for started titles, Again for finished ones, otherwise Read/Listen.
    static func buttonKey(_ title: Title, state: ReadingState?) -> String {
        guard let state else { return title.kind.readingKey }
        if state.completed { return title.kind.againKey }
        return state.started ? title.kind.continueKey : title.kind.readingKey
    }
}

/// The list behind "All" for stalled titles, on Start and in the statistics sheet.
struct StalledList: View {

    @Environment(LibraryService.self) private var inventory

    var body: some View {
        List {
            ForEach(inventory.shelf.stalled) { l in
                EntryRow(
                    entry: .title(l.title), secondaryLine: Text(verbatim: StatisticsView.stalledRow(l)),
                    withKind: true
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .paper()
        .navigationTitle(Text(app: "statistics.stalled"))
        .toolbarTitleDisplayMode(.inline)
    }
}
