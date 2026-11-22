import AppIntents
import SwiftUI
import WidgetBridge
import WidgetKit

/// An entry of the "Continue listening" timeline: the snapshot and the time for
/// which remaining time and bar are computed.
struct AudioEntry: TimelineEntry {
    let date: Date
    let snapshot: ContinueListeningSnapshot?
    let folder: URL?

    var audiobook: ContinueListeningSnapshot.Audiobook? { snapshot?.audiobook }
    var remainder: TimeInterval { snapshot?.remainder(asOf: date) ?? 0 }
    var fraction: Double { snapshot?.fraction(asOf: date) ?? 0 }
}

/// Delivers the timeline: if the audiobook is stopped, **one** entry without expiry - the app
/// writes and reloads when something happens. If it is playing, one entry per minute for
/// the next hour (or until the end) so remaining time and bar keep moving without
/// the app writing; afterwards the system reloads and reads what the app has stored by
/// then (a fresh state every five minutes).
struct AudioProvider: TimelineProvider {

    func placeholder(in context: Context) -> AudioEntry {
        AudioEntry(date: Date(), snapshot: .sample, folder: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (AudioEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current(asOf: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AudioEntry>) -> Void) {
        let now = Date()
        let firstMatch = current(asOf: now)
        guard let snapshot = firstMatch.snapshot, let end = snapshot.end(from: now) else {
            completion(Timeline(entries: [firstMatch], policy: .never))
            return
        }
        let until = min(end, now.addingTimeInterval(60 * 60))
        var entries = [firstMatch]
        var tick = now.addingTimeInterval(60)
        while tick < until {
            entries.append(
                AudioEntry(date: tick, snapshot: snapshot, folder: firstMatch.folder))
            tick = tick.addingTimeInterval(60)
        }
        entries.append(AudioEntry(date: until, snapshot: snapshot, folder: firstMatch.folder))
        completion(Timeline(entries: entries, policy: .after(until)))
    }

    private func current(asOf date: Date) -> AudioEntry {
        let folder = SnapshotStore.continueListeningFolder()
        let snapshot = folder.flatMap { SnapshotStore.readContinueListening(from: $0) }
        return AudioEntry(date: date, snapshot: snapshot, folder: folder)
    }
}

extension ContinueListeningSnapshot {

    /// An invented audiobook for gallery and placeholder - not playing, without cover.
    static let sample = ContinueListeningSnapshot(
        profile: "Alex",
        audiobook: Audiobook(
            id: "beispiel", name: "The Last Signal", subline: "Theo Marsh", chapter: "Chapter 12",
            time: 6_800,
            duration: 38_520, running: false, link: SnapshotStore.openLink, cover: nil))

    static let sampleRunning = ContinueListeningSnapshot(
        profile: "Sam", multipleProfiles: true,
        audiobook: Audiobook(
            id: "beispiel", name: "The Glass Orchard", subline: "Ines Moreau",
            chapter: "Part II · The Harvest",
            time: 40_000, duration: 76_000, tempo: 1.25, running: true, link: SnapshotStore.openLink,
            cover: nil))
}

/// The "Continue listening" widget: small has cover, name, remaining time and the play/pause button;
/// medium adds author, chapter and bar; on the lock screen name, chapter,
/// remaining time. A tap beside the button leads into the player via `akari://lesen/...`.
struct ContinueListeningWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SnapshotStore.continueListeningKind, provider: AudioProvider()) { entry in
            ContinueListeningView(entry: entry)
                .containerBackground(for: .widget) { WidgetLook.paper }
        }
        .configurationDisplayName(Text("widget.listen.name"))
        .description(Text("widget.listen.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ContinueListeningView: View {

    let entry: AudioEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let audiobook = entry.audiobook {
            switch family {
            case .systemMedium:
                AudioMediumView(entry: entry, audiobook: audiobook)
                    .widgetURL(audiobook.link)
            case .accessoryRectangular:
                AudioRowView(entry: entry, audiobook: audiobook)
                    .widgetURL(audiobook.link)
            default:
                AudioSmallView(entry: entry, audiobook: audiobook)
                    .widgetURL(audiobook.link)
            }
        } else {
            AudioPlaceholderView(small: family == .accessoryRectangular)
                .widgetURL(SnapshotStore.openLink)
        }
    }
}

// MARK: - Small

/// Cover top left, beside it badge and name; below the remaining time and on the right the
/// button - text beside the cover, never on it.
struct AudioSmallView: View {

    let entry: AudioEntry
    let audiobook: ContinueListeningSnapshot.Audiobook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AudioCover(audiobook: audiobook, folder: entry.folder, width: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("widget.kind.hoerbuch")
                        .font(WidgetLook.badge)
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(WidgetLook.muted)
                    Text(verbatim: audiobook.name)
                        .font(WidgetLook.name(.subheadline))
                        .foregroundStyle(WidgetLook.typography)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                TimeLeft(entry: entry, audiobook: audiobook)
                Spacer(minLength: 4)
                AudioButton(audiobook: audiobook, size: 34)
            }
        }
    }
}

// MARK: - Medium

/// Cover on the left (tap -> player), on the right badge, name, author, chapter, below the
/// bar with remaining time and the button.
struct AudioMediumView: View {

    let entry: AudioEntry
    let audiobook: ContinueListeningSnapshot.Audiobook

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Link(destination: audiobook.link) {
                AudioCover(audiobook: audiobook, folder: entry.folder, width: 92)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("widget.listen.name")
                        .font(WidgetLook.badge)
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(WidgetLook.muted)
                    Spacer()
                    if entry.snapshot?.multipleProfiles == true,
                        let profile = entry.snapshot?.profile
                    {
                        Text(verbatim: profile)
                            .font(.caption2)
                            .foregroundStyle(WidgetLook.muted)
                    }
                }
                Text(verbatim: audiobook.name)
                    .font(WidgetLook.name(.subheadline))
                    .foregroundStyle(WidgetLook.typography)
                    .lineLimit(2)
                if let subline = audiobook.subline {
                    Text(verbatim: subline)
                        .font(.caption2)
                        .foregroundStyle(WidgetLook.muted)
                        .lineLimit(1)
                }
                if let chapter = audiobook.chapter {
                    Text(verbatim: chapter)
                        .font(.caption)
                        .foregroundStyle(WidgetLook.typography)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        AudioBar(fraction: entry.fraction)
                        TimeLeft(entry: entry, audiobook: audiobook)
                    }
                    AudioButton(audiobook: audiobook, size: 36)
                }
            }
        }
    }
}

// MARK: - Lock screen

/// Headphones, name, chapter and remaining time - single-color, as the system draws there.
struct AudioRowView: View {

    let entry: AudioEntry
    let audiobook: ContinueListeningSnapshot.Audiobook

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: audiobook.running ? "headphones.circle.fill" : "headphones")
                .font(.title3)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: audiobook.name)
                    .font(.headline)
                    .lineLimit(1)
                if let chapter = audiobook.chapter {
                    Text(verbatim: chapter)
                        .font(.caption)
                        .lineLimit(1)
                }
                Text(verbatim: Phrase.from("widget.remainder", WidgetLook.time(entry.remainder)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Empty

struct AudioPlaceholderView: View {

    let small: Bool

    var body: some View {
        if small {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .font(.title3)
                    .widgetAccentable()
                Text("widget.listen.empty.title")
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "headphones")
                    .font(.title2)
                    .foregroundStyle(WidgetLook.accent)
                Text("widget.listen.empty.title")
                    .font(WidgetLook.name(.subheadline))
                    .foregroundStyle(WidgetLook.typography)
                    .multilineTextAlignment(.center)
                Text("widget.listen.empty.text")
                    .font(.caption2)
                    .foregroundStyle(WidgetLook.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Building blocks

/// The play/pause button: an `AppIntent` that the system executes in the app
/// (``WeiterhoerenIntent``). Round, in the accent, the glyph on it in the color of the
/// paper - like the app's primary button.
struct AudioButton: View {

    let audiobook: ContinueListeningSnapshot.Audiobook
    let size: CGFloat

    var body: some View {
        Button(intent: WeiterhoerenIntent(kennung: audiobook.id, link: audiobook.link)) {
            Image(systemName: audiobook.running ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(WidgetLook.paper)
                .frame(width: size, height: size)
                .background(WidgetLook.accent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(audiobook.running ? "widget.listen.pause" : "widget.listen.play"))
    }
}

/// "3 h 12 min left" - with fixed digit width so the number does not jump each minute.
struct TimeLeft: View {

    let entry: AudioEntry
    let audiobook: ContinueListeningSnapshot.Audiobook

    var body: some View {
        Text(verbatim: Phrase.from("widget.remainder", WidgetLook.time(entry.remainder)))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(WidgetLook.muted)
            .lineLimit(1)
    }
}

struct AudioBar: View {

    let fraction: Double

    var body: some View {
        GeometryReader { mass in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetLook.surface)
                Capsule().fill(WidgetLook.accent)
                    .frame(width: max(mass.size.width * fraction, 4))
            }
        }
        .frame(height: 4)
    }
}

/// The cover - square, like audiobooks in the app; without a file the headphones on
/// the surface.
struct AudioCover: View {

    let audiobook: ContinueListeningSnapshot.Audiobook
    let folder: URL?
    let width: CGFloat

    var body: some View {
        ZStack {
            WidgetLook.surface
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: width * 0.4))
                    .foregroundStyle(WidgetLook.muted)
            }
        }
        .frame(width: width, height: width)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(WidgetLook.hairline, lineWidth: 0.5))
    }

    private var image: UIImage? {
        guard let folder, let path = SnapshotStore.cover(audiobook, in: folder) else { return nil }
        return UIImage(contentsOfFile: path.path)
    }
}

// MARK: - Preview

#Preview("Klein", as: .systemSmall) {
    ContinueListeningWidget()
} timeline: {
    AudioEntry(date: .now, snapshot: .sample, folder: nil)
    AudioEntry(date: .now, snapshot: .sampleRunning, folder: nil)
    AudioEntry(date: .now, snapshot: .empty(profile: "Alex"), folder: nil)
}

#Preview("Mittel", as: .systemMedium) {
    ContinueListeningWidget()
} timeline: {
    AudioEntry(date: .now, snapshot: .sample, folder: nil)
    AudioEntry(date: .now, snapshot: .sampleRunning, folder: nil)
    AudioEntry(date: .now, snapshot: .empty(profile: "Alex"), folder: nil)
}

#Preview("Sperrbildschirm", as: .accessoryRectangular) {
    ContinueListeningWidget()
} timeline: {
    AudioEntry(date: .now, snapshot: .sampleRunning, folder: nil)
    AudioEntry(date: .now, snapshot: .empty(profile: "Alex"), folder: nil)
}
