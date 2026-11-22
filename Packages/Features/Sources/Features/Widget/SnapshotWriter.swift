import Bedrock
import CoreGraphics
import Foundation
import ImageIO
import Library
import OfflineStore
import SourcesKit
import UniformTypeIdentifiers
import WidgetBridge

#if canImport(WidgetKit)
    import WidgetKit
#endif

extension ContinueReadingSnapshot {

    /// The snapshot from the continue-reading row, in the same order as on Start (newest
    /// first, reading and listening mixed), capped at four. Name and subline like the
    /// tile: for manga the series name and "Volume 47", otherwise the title and the first
    /// author. The link leads into the reader.
    static func from(
        _ readings: [Shelf.Reading], profile: String, multipleProfiles: Bool, now: Date = Date()
    ) -> ContinueReadingSnapshot {
        let entries = readings.prefix(cap).map { reading -> Item in
            let title = reading.title
            let display = Display(title, inBookSeries: false)
            return Item(
                id: title.identifier.description,
                name: display.name,
                subline: display.volume ?? title.authors.first,
                kind: Kind(rawValue: title.kind.rawValue) ?? .book,
                fraction: reading.state.fraction,
                state: Formats.short(reading.state),
                link: Deeplink.read(title.identifier).url,
                cover: title.cover == nil ? nil : coverFilename(for: title.identifier.description))
        }
        return ContinueReadingSnapshot(
            profile: profile, multipleProfiles: multipleProfiles, entries: Array(entries), written: now)
    }
}

/// Writes the "Continue reading" snapshot into the app group and wakes the widget.
///
/// **Coalesced, not on every page turn:** the `PositionReporter` writes a state every two
/// seconds, and each one changes the continue-reading row. The widget need not follow
/// that: ``schedule(_:sources:)`` waits two seconds and writes the latest state; when going
/// to the background it goes out immediately (``immediately()``), so the widget shows
/// what the app last knew.
///
/// **The covers come from the image loader**, mostly from disk because the start page
/// has just drawn them, and go into the folder as JPEG with at most 300 pixels; what is
/// already there is not fetched again. What stays the same (same snapshot, same covers)
/// is not written again.
@MainActor
final class SnapshotWriter {

    /// The longer edge of the cover file; 300 is enough for 2x at 110 pt tile width.
    static let coverEdge = 300
    static let waitTime: Duration = .seconds(2)

    private let folder: URL?
    private let imageLoader: ImageLoader
    private var planned: Task<Void, Never>?
    private var pending: (job: Job, sources: SourceAccess)?
    private var recently: ContinueReadingSnapshot?

    /// What the widget should show, as a value so the shell with `onChange` only writes
    /// when something about it has changed.
    struct Job: Equatable {
        let readings: [Shelf.Reading]
        let profile: String
        let multipleProfiles: Bool
    }

    /// What the covers are fetched with: headers and transport of the source.
    struct SourceAccess {
        let headerLines: @MainActor (SourceID) -> [String: String]
        let transport: @Sendable (Provider) -> any Transport
    }

    /// - Parameter folder: the snapshot folder; in operation the one from the app group,
    ///   in tests one under `tmp`; `nil` means no group, write nothing.
    init(folder: URL? = SnapshotStore.folder(), imageLoader: ImageLoader = .shared) {
        self.folder = folder
        self.imageLoader = imageLoader
    }

    /// Remembers the job and writes it after the wait; a new one replaces the previous
    /// one, and the last one is written.
    func schedule(_ job: Job, sources: SourceAccess) {
        pending = (job, sources)
        planned?.cancel()
        planned = Task { [weak self] in
            try? await Task.sleep(for: SnapshotWriter.waitTime)
            guard !Task.isCancelled else { return }
            self?.planned = nil
            await self?.writePending()
        }
    }

    /// Writes what is pending without waiting, when going to the background.
    func immediately() async {
        planned?.cancel()
        planned = nil
        await writePending()
    }

    private func writePending() async {
        guard let (job, sources) = pending else { return }
        pending = nil
        await write(job, sources: sources)
    }

    private func write(_ job: Job, sources: SourceAccess) async {
        guard let folder else { return }
        let snapshot = ContinueReadingSnapshot.from(
            job.readings, profile: job.profile, multipleProfiles: job.multipleProfiles)
        let present = SnapshotStore.existingCovers(in: folder)
        let missing = job.readings.prefix(ContinueReadingSnapshot.cap).compactMap {
            reading -> (String, Shelf.Reading)? in
            let name = ContinueReadingSnapshot.coverFilename(for: reading.title.identifier.description)
            guard reading.title.cover != nil, !present.contains(name) else { return nil }
            return (name, reading)
        }
        if missing.isEmpty, let recently, recently.entries == snapshot.entries,
            recently.profile == snapshot.profile,
            recently.multipleProfiles == snapshot.multipleProfiles
        {
            return
        }
        var cover: [String: Data] = [:]
        for (name, reading) in missing {
            guard let address = reading.title.cover else { continue }
            let source = reading.title.identifier.source
            let image = await imageLoader.image(
                address, headerLines: sources.headerLines(source),
                pixels: SnapshotWriter.coverEdge,
                transport: sources.transport(source.provider))
            if let image, let data = SnapshotWriter.jpeg(image) { cover[name] = data }
        }
        do {
            try SnapshotStore.write(snapshot, cover: cover, in: folder)
            recently = snapshot
            Diagnostics.step(
                "Widget: \(snapshot.entries.count) titles, \(cover.count) covers new", since: nil,
                area: "Widget")
            #if canImport(WidgetKit)
                WidgetCenter.shared.reloadTimelines(ofKind: SnapshotStore.widgetKind)
            #endif
        } catch {
            Diagnostics.network.error(
                "Widget snapshot not written: \(String(describing: error), privacy: .public)")
        }
    }

    /// The image as JPEG, quality 0.8: small enough for four files, good enough for 110 pt.
    nonisolated static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            target, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return data as Data
    }
}
