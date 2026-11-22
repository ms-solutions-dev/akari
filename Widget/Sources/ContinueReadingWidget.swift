import SwiftUI
import WidgetBridge
import WidgetKit

/// The "Continue reading" widget: small one title, medium up to three, on the
/// lock screen one as a line. A tap leads via `akari://lesen/...`
/// straight into the reader - not to the start page.
struct ContinueReadingWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SnapshotStore.widgetKind, provider: SnapshotProvider()) {
            entry in
            ContinueReadingView(entry: entry)
                .containerBackground(for: .widget) { WidgetLook.paper }
        }
        .configurationDisplayName(Text("widget.name"))
        .description(Text("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

/// Distributes over the family - and for an empty snapshot shows "Nothing
/// started yet" with the open link, in every size.
struct ContinueReadingView: View {

    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.entries.isEmpty {
            PlaceholderView(small: family == .accessoryRectangular)
                .widgetURL(SnapshotStore.openLink)
        } else {
            switch family {
            case .systemMedium:
                MediumView(entry: entry)
            case .accessoryRectangular:
                RowView(title: entry.entries[0])
                    .widgetURL(entry.entries[0].link)
            default:
                SmallView(title: entry.entries[0], folder: entry.folder)
                    .widgetURL(entry.entries[0].link)
            }
        }
    }
}

// MARK: - Small

/// One title: cover on the left, name and secondary line on the right, the bar at the bottom across the
/// full width - text beside the cover, never on it.
struct SmallView: View {

    let title: ContinueReadingSnapshot.Item
    let folder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                CoverArt(title: title, folder: folder, width: 46)
                VStack(alignment: .leading, spacing: 3) {
                    KindBadge(kind: title.kind)
                    Text(verbatim: title.name)
                        .font(WidgetLook.name(.subheadline))
                        .foregroundStyle(WidgetLook.typography)
                        .lineLimit(3)
                    if let subline = title.subline {
                        Text(verbatim: subline)
                            .font(.caption2)
                            .foregroundStyle(WidgetLook.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            ProgressStrip(title: title)
        }
    }
}

// MARK: - Medium

/// Up to three titles side by side: cover, name, bar - above them the line
/// "Continue reading" and, if there are several profiles, the profile's name.
struct MediumView: View {

    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("widget.continueReading")
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
            HStack(alignment: .top, spacing: 12) {
                ForEach(entry.entries.prefix(3)) { title in
                    Link(destination: title.link) {
                        Column(title: title, folder: entry.folder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// One column: cover, name, bar - everything left-aligned, the bar at the bottom.
    private struct Column: View {
        let title: ContinueReadingSnapshot.Item
        let folder: URL?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    CoverArt(title: title, folder: folder, width: 38)
                    Text(verbatim: title.name)
                        .font(WidgetLook.name(.caption))
                        .foregroundStyle(WidgetLook.typography)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                ProgressStrip(title: title, withNumber: false)
            }
        }
    }
}

// MARK: - Lock screen

/// The line on the lock screen: glyph of the kind, name, the state in words.
/// No cover - the system draws single-color there.
struct RowView: View {

    let title: ContinueReadingSnapshot.Item

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: KindBadge.glyph(title.kind))
                .font(.title3)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title.name)
                    .font(.headline)
                    .lineLimit(2)
                if let state = title.state {
                    Text(verbatim: state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Empty

/// "Nothing started yet" - a sentence, a glyph, and the whole frame is the
/// open link. On the lock screen just the line.
struct PlaceholderView: View {

    let small: Bool

    var body: some View {
        if small {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.title3)
                    .widgetAccentable()
                Text("widget.empty.title")
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "books.vertical")
                    .font(.title2)
                    .foregroundStyle(WidgetLook.accent)
                Text("widget.empty.title")
                    .font(WidgetLook.name(.subheadline))
                    .foregroundStyle(WidgetLook.typography)
                    .multilineTextAlignment(.center)
                Text("widget.empty.text")
                    .font(.caption2)
                    .foregroundStyle(WidgetLook.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Building blocks

/// The cover from the app group - or the placeholder of the kind on the surface.
/// Portrait 2 : 3 for book and manga, square for audiobook, as in the app.
struct CoverArt: View {

    let title: ContinueReadingSnapshot.Item
    let folder: URL?
    let width: CGFloat

    var body: some View {
        let height = title.kind.isAudible ? width : width * 1.5
        ZStack {
            WidgetLook.surface
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: KindBadge.glyph(title.kind))
                    .font(.system(size: width * 0.4))
                    .foregroundStyle(WidgetLook.muted)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(WidgetLook.hairline, lineWidth: 0.5))
    }

    private var image: UIImage? {
        guard let folder, let path = SnapshotStore.cover(title, in: folder) else { return nil }
        return UIImage(contentsOfFile: path.path)
    }
}

/// The badge of the kind - "BOOK", "MANGA", "AUDIOBOOK", letter-spaced and small.
struct KindBadge: View {

    let kind: ContinueReadingSnapshot.Kind

    var body: some View {
        Text(LocalizedStringKey("widget.kind." + kind.rawValue))
            .font(WidgetLook.badge)
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(WidgetLook.muted)
    }

    static func glyph(_ kind: ContinueReadingSnapshot.Kind) -> String {
        switch kind {
        case .manga: "book.pages"
        case .book: "book.closed"
        case .audiobook: "headphones"
        case .podcast: "antenna.radiowaves.left.and.right"
        }
    }
}

/// The bar with the state beside it - accent on surface, fixed digit width.
struct ProgressStrip: View {

    let title: ContinueReadingSnapshot.Item
    var withNumber = true

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { mass in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetLook.surface)
                    Capsule().fill(WidgetLook.accent)
                        .frame(width: max(mass.size.width * title.fraction, 4))
                }
            }
            .frame(height: 4)
            if withNumber, let state = title.state {
                Text(verbatim: state)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(WidgetLook.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

// MARK: - Preview

#Preview("Klein", as: .systemSmall) {
    ContinueReadingWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample, folder: nil)
    SnapshotEntry(date: .now, snapshot: .empty(profile: "Alex"), folder: nil)
}

#Preview("Mittel", as: .systemMedium) {
    ContinueReadingWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample, folder: nil)
    SnapshotEntry(
        date: .now,
        snapshot: ContinueReadingSnapshot(
            profile: "Sam", multipleProfiles: true,
            entries: Array(ContinueReadingSnapshot.sample.entries.prefix(1))),
        folder: nil)
}

#Preview("Sperrbildschirm", as: .accessoryRectangular) {
    ContinueReadingWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample, folder: nil)
}
