import Foundation
import WidgetBridge
import WidgetKit

/// An entry of the timeline: the snapshot as it lies in the app group -
/// `nil` as long as the app has not written one yet.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: ContinueReadingSnapshot?
    /// The folder with the covers - `nil` in the preview, then they stay placeholders.
    let folder: URL?

    var entries: [ContinueReadingSnapshot.Item] { snapshot?.entries ?? [] }
}

/// Delivers the widget its timeline: **one** entry, without expiry time. The
/// widget computes nothing ahead - the app writes the snapshot and calls
/// `reloadTimelines` when something changed. A timeline with dates
/// would have nothing to show that the app does not already know.
///
/// In the gallery (`context.isPreview`) and as a placeholder a built
/// sample with three titles stands, so the widget does not say "Nothing started yet"
/// there before anyone has added it.
struct SnapshotProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample, folder: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(current())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> SnapshotEntry {
        let folder = SnapshotStore.folder()
        let snapshot = folder.flatMap { SnapshotStore.load(from: $0) }
        return SnapshotEntry(date: Date(), snapshot: snapshot, folder: folder)
    }
}

extension ContinueReadingSnapshot {

    /// Three invented titles for gallery and placeholder - without cover, without server.
    static let sample = ContinueReadingSnapshot(
        profile: "Alex",
        entries: [
            Item(
                id: "beispiel-1", name: "The Glass Orchard", subline: "Ines Moreau", kind: .book,
                fraction: 0.42, state: "42 %", link: SnapshotStore.openLink, cover: nil),
            Item(
                id: "beispiel-2", name: "Pepper&Carrot", subline: "Vol. 37", kind: .manga, fraction: 0.31,
                state: "S. 63/205", link: SnapshotStore.openLink, cover: nil),
            Item(
                id: "beispiel-3", name: "The Last Signal", subline: "Theo Marsh", kind: .audiobook,
                fraction: 0.67, state: "3 h 12 min left", link: SnapshotStore.openLink, cover: nil),
        ])
}
