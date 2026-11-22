import AudioPlayer
import Bedrock
import Foundation
import Library
import OfflineStore
import SourcesKit
import WidgetBridge

#if canImport(WidgetKit)
    import WidgetKit
#endif

/// What the player currently holds, as a value so the job is comparable.
struct PlayerState: Equatable {
    let title: Title
    let chapter: String?
    let time: TimeInterval
    let duration: TimeInterval
    let tempo: Double
    let running: Bool

    /// The state from the running player, or `nil` if it is empty. The player does not
    /// know the `Title` (it holds an `AudioPlayer/Audiobook` with the identifier as
    /// text); it comes from the ``ReadCall`` (`ongoing`, set by the audio sheet), otherwise the shelf.
    @MainActor
    static func from(_ player: Player, ongoing: Title?, shelf: Shelf) -> PlayerState? {
        guard let audiobook = player.audiobook else { return nil }
        let title =
            ongoing?.identifier.description == audiobook.id
            ? ongoing : shelf.allTitles.first { $0.identifier.description == audiobook.id }
        guard let title else { return nil }
        return PlayerState(
            title: title, chapter: player.chapter?.name, time: player.time, duration: player.duration,
            tempo: player.tempo, running: player.running)
    }
}

extension ContinueListeningSnapshot {

    /// The snapshot: the audiobook in the player, with chapter, position and whether it
    /// is running; otherwise the most recent listening reading of the shelf (which knows
    /// no chapter, only the state; without a second in the state the share is computed
    /// over the title's duration).
    static func from(
        player: PlayerState?, reading: Shelf.Reading?, profile: String, multipleProfiles: Bool,
        now: Date = Date()
    ) -> ContinueListeningSnapshot {
        let audiobook: Audiobook?
        if let player {
            audiobook = Audiobook(
                id: player.title.identifier.description, name: player.title.name,
                subline: player.title.authors.first ?? player.title.narrator.first,
                chapter: player.chapter, time: player.time, duration: player.duration, tempo: player.tempo,
                running: player.running, link: Deeplink.read(player.title.identifier).url,
                cover: player.title.cover == nil
                    ? nil : ContinueReadingSnapshot.coverFilename(for: player.title.identifier.description))
        } else if let reading {
            let title = reading.title
            let (time, duration): (TimeInterval, TimeInterval) =
                switch (reading.state.position, title.scope) {
                case (.second(let s, let from), _) where from > 0: (s, from)
                case (_, .duration(let d)): (reading.state.fraction * d, d)
                default: (reading.state.fraction, 1)
                }
            audiobook = Audiobook(
                id: title.identifier.description, name: title.name,
                subline: title.authors.first ?? title.narrator.first, chapter: nil, time: time,
                duration: duration,
                running: false, link: Deeplink.read(title.identifier).url,
                cover: title.cover == nil
                    ? nil : ContinueReadingSnapshot.coverFilename(for: title.identifier.description))
        } else {
            audiobook = nil
        }
        return ContinueListeningSnapshot(
            profile: profile, multipleProfiles: multipleProfiles, audiobook: audiobook, written: now)
    }
}

/// Writes the "Continue listening" snapshot into the app group and wakes the widget.
///
/// **What changes a job:** audiobook, chapter, running/stopped, speed, and the position,
/// but only in steps of five minutes (``Job/==``): the player advances the time twice per
/// second, and the widget keeps computing the remaining time from
/// ``ContinueListeningSnapshot/written`` itself. A sync every five minutes catches what
/// the widget cannot see, such as a track ending or the sleep timer. On pause, jump and
/// chapter change the job goes out immediately, because one of the other fields changes.
///
/// Coalesced as in the continue-reading writer: two seconds after the last change, and
/// immediately when going to the background and after the play/pause intent.
@MainActor
final class ContinueListeningWriter {

    static let waitTime: Duration = .seconds(2)
    /// The time step in which a running position counts as "changed".
    nonisolated static let timeStep: TimeInterval = 5 * 60

    private let folder: URL?
    private let imageLoader: ImageLoader
    private var planned: Task<Void, Never>?
    private var pending: (job: Job, sources: SnapshotWriter.SourceAccess)?
    private var recently: ContinueListeningSnapshot?

    struct Job: Equatable {
        let player: PlayerState?
        let reading: Shelf.Reading?
        let profile: String
        let multipleProfiles: Bool

        static func == (a: Job, b: Job) -> Bool {
            guard a.profile == b.profile, a.multipleProfiles == b.multipleProfiles, a.reading == b.reading
            else {
                return false
            }
            switch (a.player, b.player) {
            case (nil, nil): return true
            case (let x?, let y?):
                return x.title == y.title && x.chapter == y.chapter && x.running == y.running
                    && x.tempo == y.tempo
                    && x.duration == y.duration
                    && (x.time / ContinueListeningWriter.timeStep).rounded(.down)
                        == (y.time / ContinueListeningWriter.timeStep).rounded(.down)
            default: return false
            }
        }

        /// The job from player and shelf, the same for the guard and the intent.
        @MainActor
        static func from(
            _ player: Player, ongoing: Title?, shelf: Shelf, profile: String, multipleProfiles: Bool
        ) -> Job {
            Job(
                player: PlayerState.from(player, ongoing: ongoing, shelf: shelf),
                reading: shelf.continueReading.first { $0.title.kind.isAudible }, profile: profile,
                multipleProfiles: multipleProfiles)
        }
    }

    init(folder: URL? = SnapshotStore.continueListeningFolder(), imageLoader: ImageLoader = .shared) {
        self.folder = folder
        self.imageLoader = imageLoader
    }

    func schedule(_ job: Job, sources: SnapshotWriter.SourceAccess) {
        pending = (job, sources)
        planned?.cancel()
        planned = Task { [weak self] in
            try? await Task.sleep(for: ContinueListeningWriter.waitTime)
            guard !Task.isCancelled else { return }
            self?.planned = nil
            await self?.writePending()
        }
    }

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

    private func write(_ job: Job, sources: SnapshotWriter.SourceAccess) async {
        guard let folder else { return }
        let snapshot = ContinueListeningSnapshot.from(
            player: job.player, reading: job.reading, profile: job.profile,
            multipleProfiles: job.multipleProfiles)
        let title = job.player?.title ?? job.reading?.title
        var cover: [String: Data] = [:]
        if let title, let address = title.cover, let name = snapshot.audiobook?.cover,
            !SnapshotStore.existingCovers(in: folder).contains(name)
        {
            let source = title.identifier.source
            let image = await imageLoader.image(
                address, headerLines: sources.headerLines(source),
                pixels: SnapshotWriter.coverEdge,
                transport: sources.transport(source.provider))
            if let image, let data = SnapshotWriter.jpeg(image) { cover[name] = data }
        }
        if cover.isEmpty, let recently, recently.audiobook == snapshot.audiobook,
            recently.profile == snapshot.profile,
            recently.multipleProfiles == snapshot.multipleProfiles
        {
            return
        }
        do {
            try SnapshotStore.writeContinueListening(snapshot, cover: cover, in: folder)
            recently = snapshot
            Diagnostics.step(
                "Widget continue listening: \(snapshot.audiobook?.name ?? "empty")"
                    + (snapshot.audiobook?.running == true ? " running" : ""), since: nil, area: "Widget")
            #if canImport(WidgetKit)
                WidgetCenter.shared.reloadTimelines(ofKind: SnapshotStore.continueListeningKind)
            #endif
        } catch {
            Diagnostics.network.error(
                "Widget continue-listening snapshot not written: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
