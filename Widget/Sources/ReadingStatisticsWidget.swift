import SwiftUI
import WidgetBridge
import WidgetKit

/// An entry of the "Reading statistics" timeline: the snapshot and the time
/// for which "today" and "this week" are computed.
struct StatisticsEntry: TimelineEntry {
    let date: Date
    let snapshot: ReadingStatisticsSnapshot?

    var week: ReadingStatisticsSnapshot.Week? { snapshot?.week(asOf: date) }
    var empty: Bool { snapshot?.empty ?? true }
}

/// Delivers the timeline: one entry now and one at midnight - there "today"
/// falls to 0 and the week moves on without the app running. Afterwards the
/// system reloads and reads what the app has stored by then.
struct StatisticsProvider: TimelineProvider {

    func placeholder(in context: Context) -> StatisticsEntry {
        StatisticsEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatisticsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current(asOf: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatisticsEntry>) -> Void) {
        let now = Date()
        let firstMatch = current(asOf: now)
        let midnight = ReadingStatisticsSnapshot.nextMidnight(to: now)
        let second = StatisticsEntry(date: midnight, snapshot: firstMatch.snapshot)
        completion(Timeline(entries: [firstMatch, second], policy: .after(midnight)))
    }

    private func current(asOf date: Date) -> StatisticsEntry {
        let snapshot = SnapshotStore.statisticsFolder().flatMap {
            SnapshotStore.readStatistics(from: $0)
        }
        return StatisticsEntry(date: date, snapshot: snapshot)
    }
}

extension ReadingStatisticsSnapshot {

    /// Two weeks of invented reading time for gallery and placeholder.
    static let sample: ReadingStatisticsSnapshot = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let minutes: [(book: Double, manga: Double, audiobook: Double, pages: Int)] = [
            (25, 0, 0, 0), (0, 40, 0, 110), (30, 0, 45, 0), (0, 0, 0, 0), (15, 20, 0, 60), (0, 0, 60, 0),
            (10, 35, 0, 90), (20, 0, 0, 0), (0, 0, 0, 0), (40, 0, 0, 0), (0, 25, 0, 70), (0, 0, 50, 0),
            (18, 0, 0, 0), (32, 0, 0, 0),
        ]
        let days = minutes.enumerated().map { i, m in
            Day(
                date: calendar.date(byAdding: .day, value: i - 13, to: today) ?? today, book: m.book * 60,
                manga: m.manga * 60, audiobook: m.audiobook * 60, pages: m.pages)
        }
        return ReadingStatisticsSnapshot(
            profile: "Alex", days: days, finishedMonth: 2, finishedYear: 14,
            stalled: 3)
    }()
}

/// The "Reading statistics" widget: the figures of the statistics sheet - small the
/// reading time today with week and pages, medium adds finished, reading days and the
/// week strip per kind, on the lock screen the ring (today against the week) or
/// the line. A tap opens the statistics sheet via `akari://statistik`.
struct ReadingStatisticsWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SnapshotStore.statisticsKind, provider: StatisticsProvider()) {
            entry in
            StatisticsView(entry: entry)
                .containerBackground(for: .widget) { WidgetLook.paper }
                .widgetURL(SnapshotStore.statisticsLink)
        }
        .configurationDisplayName(Text("widget.statistics.name"))
        .description(Text("widget.statistics.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct StatisticsView: View {

    let entry: StatisticsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let week = entry.week, !entry.empty {
            switch family {
            case .systemMedium: StatisticsMediumView(entry: entry, week: week)
            case .accessoryCircular: StatisticsRingView(week: week)
            case .accessoryRectangular: StatisticsRowView(week: week)
            default: StatisticsSmallView(entry: entry, week: week)
            }
        } else {
            StatisticsPlaceholderView(family: family)
        }
    }
}

// MARK: - Small

/// Badge, the reading time today large, below it "Week 3 h 10 min - 120 p." and the
/// reading days of the week.
struct StatisticsSmallView: View {

    let entry: StatisticsEntry
    let week: ReadingStatisticsSnapshot.Week

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatisticsHeader(entry: entry)
            Spacer(minLength: 0)
            Text(verbatim: WidgetLook.time(week.today))
                .font(WidgetLook.figure)
                .monospacedDigit()
                .foregroundStyle(WidgetLook.typography)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("widget.statistics.today")
                .font(.caption2)
                .foregroundStyle(WidgetLook.muted)
            Spacer(minLength: 0)
            Text(
                verbatim: Phrase.from("widget.statistics.week.line", WidgetLook.time(week.week))
                    + " · " + Phrase.from("widget.statistics.pages.short", week.pages)
            )
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(WidgetLook.typography)
            .lineLimit(1)
            if week.readingDays > 0 {
                Text(verbatim: Phrase.from("widget.statistics.readingDays.line", week.readingDays))
                    .font(.caption2)
                    .foregroundStyle(WidgetLook.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Medium

/// On the left the numbers (Today, Week, Pages, Finished, Reading days), on the right the week strip
/// with the weekdays; below the strip, what was left over.
struct StatisticsMediumView: View {

    let entry: StatisticsEntry
    let week: ReadingStatisticsSnapshot.Week

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatisticsHeader(entry: entry)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    NumbersRow(
                        name: "widget.statistics.today", value: WidgetLook.time(week.today),
                        large: true
                    )
                    NumbersRow(name: "widget.statistics.week", value: WidgetLook.time(week.week))
                    NumbersRow(name: "widget.statistics.pages", value: week.pages.formatted())
                    NumbersRow(
                        name: "widget.statistics.finished",
                        value: (entry.snapshot?.finishedMonth ?? 0).formatted())
                    NumbersRow(name: "widget.statistics.readingDays", value: week.readingDays.formatted())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    WeekStrip(days: week.days)
                    if let s = entry.snapshot, s.stalled > 0 {
                        Text(verbatim: Phrase.from("widget.statistics.stalled", s.stalled))
                            .font(.caption2)
                            .foregroundStyle(WidgetLook.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// "Today  32 min" - name on the left muted, value on the right with fixed digit width.
    private struct NumbersRow: View {
        let name: LocalizedStringKey
        let value: String
        var large = false

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(WidgetLook.muted)
                Spacer(minLength: 0)
                Text(verbatim: value)
                    .font(large ? WidgetLook.name(.subheadline) : .caption)
                    .fontWeight(large ? .semibold : .medium)
                    .monospacedDigit()
                    .foregroundStyle(WidgetLook.typography)
            }
            .lineLimit(1)
        }
    }
}

/// Seven bars, stacked per day by kind (book, manga, audiobook in the three
/// accents), below them the weekday; the tallest day fills the height.
struct WeekStrip: View {

    let days: [ReadingStatisticsSnapshot.Day]

    var body: some View {
        let highest = max(days.map(\.total).max() ?? 0, 60)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(days) { tag in
                VStack(spacing: 3) {
                    GeometryReader { mass in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            if tag.total == 0 {
                                Capsule().fill(WidgetLook.surface).frame(height: 3)
                            } else {
                                VStack(spacing: 1) {
                                    BarSegment(
                                        time: tag.audiobook, from: highest, height: mass.size.height,
                                        color: WidgetLook.audiobook)
                                    BarSegment(
                                        time: tag.manga, from: highest, height: mass.size.height,
                                        color: WidgetLook.manga)
                                    BarSegment(
                                        time: tag.book, from: highest, height: mass.size.height,
                                        color: WidgetLook.book)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            }
                        }
                    }
                    Text(verbatim: tag.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(WidgetLook.muted)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("widget.statistics.week"))
        .accessibilityValue(Text(verbatim: WidgetLook.time(days.reduce(0) { $0 + $1.total })))
    }

    private struct BarSegment: View {
        let time: TimeInterval
        let from: TimeInterval
        let height: CGFloat
        let color: Color

        var body: some View {
            if time > 0 {
                Rectangle().fill(color).frame(height: max(height * time / from, 2))
            }
        }
    }
}

// MARK: - Lock screen

/// The ring: today as a share of the week, the minutes in the middle - no
/// daily goal; the app has none, and the widget introduces none.
struct StatisticsRingView: View {

    let week: ReadingStatisticsSnapshot.Week

    var body: some View {
        Gauge(value: week.fractionToday) {
            Text("widget.statistics.today")
        } currentValueLabel: {
            VStack(spacing: -2) {
                Text(verbatim: Int((week.today / 60).rounded()).formatted())
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text("widget.statistics.min")
                    .font(.system(size: 9))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}

/// "Today 32 min - 120 p. - 5 reading days" under the widget's name.
struct StatisticsRowView: View {

    let week: ReadingStatisticsSnapshot.Week

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar")
                .font(.title3)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 2) {
                Text("widget.statistics.name")
                    .font(.headline)
                    .lineLimit(1)
                Text(
                    verbatim: [
                        Phrase.from("widget.statistics.today.line", WidgetLook.time(week.today)),
                        Phrase.from("widget.statistics.pages.short", week.pages),
                        Phrase.from("widget.statistics.readingDays.line", week.readingDays),
                    ].joined(separator: " · ")
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Empty

struct StatisticsPlaceholderView: View {

    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: 0) {
                Text("widget.statistics.today")
            } currentValueLabel: {
                Image(systemName: "book.closed")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.title3)
                    .widgetAccentable()
                Text("widget.statistics.empty.title")
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        default:
            VStack(spacing: 6) {
                Image(systemName: "chart.bar")
                    .font(.title2)
                    .foregroundStyle(WidgetLook.accent)
                Text("widget.statistics.empty.title")
                    .font(WidgetLook.name(.subheadline))
                    .foregroundStyle(WidgetLook.typography)
                    .multilineTextAlignment(.center)
                Text("widget.statistics.empty.text")
                    .font(.caption2)
                    .foregroundStyle(WidgetLook.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Building blocks

/// "READING STATISTICS" and, with several profiles, the name on the right.
struct StatisticsHeader: View {

    let entry: StatisticsEntry

    var body: some View {
        HStack {
            Text("widget.statistics.name")
                .font(WidgetLook.badge)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(WidgetLook.muted)
            Spacer()
            if entry.snapshot?.multipleProfiles == true, let profile = entry.snapshot?.profile {
                Text(verbatim: profile)
                    .font(.caption2)
                    .foregroundStyle(WidgetLook.muted)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Preview

#Preview("Klein", as: .systemSmall) {
    ReadingStatisticsWidget()
} timeline: {
    StatisticsEntry(date: .now, snapshot: .sample)
    StatisticsEntry(date: .now, snapshot: .empty(profile: "Alex"))
}

#Preview("Mittel", as: .systemMedium) {
    ReadingStatisticsWidget()
} timeline: {
    StatisticsEntry(date: .now, snapshot: .sample)
    StatisticsEntry(
        date: ReadingStatisticsSnapshot.nextMidnight(to: .now), snapshot: .sample)
    StatisticsEntry(date: .now, snapshot: .empty(profile: "Alex"))
}

#Preview("Ring", as: .accessoryCircular) {
    ReadingStatisticsWidget()
} timeline: {
    StatisticsEntry(date: .now, snapshot: .sample)
    StatisticsEntry(date: .now, snapshot: .empty(profile: "Alex"))
}

#Preview("Sperrbildschirm", as: .accessoryRectangular) {
    ReadingStatisticsWidget()
} timeline: {
    StatisticsEntry(date: .now, snapshot: .sample)
    StatisticsEntry(date: .now, snapshot: .empty(profile: "Alex"))
}
