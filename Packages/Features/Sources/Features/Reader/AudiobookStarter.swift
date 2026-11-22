import AudioPlayer
import Bedrock
import Foundation
import Library
import OfflineStore
import ReadingProgress
import SourcesKit

/// Puts an audiobook into the player, without a sheet and without a SwiftUI environment.
///
/// This used to be possible only for ``AudioPlayerSheet``: it took source, volume and
/// state from its environment and built the `AudioPlayer/Audiobook` from them. The
/// play button of the "Continue listening" widget, however, runs in the app's process
/// **without** a scene: the app was quit or evicted by the system, and the system starts
/// it in the background for the intent. There is no environment, no sheet, no library
/// from persistence. So the path from title to playing audiobook is extracted here: the
/// sheet calls ``load(_:start:)`` and afterwards only shows `AudioPlayer/AudioPlayerView`;
/// ``AppCore`` calls ``launch(_:)`` with an identifier, and the player plays as if the
/// sheet had been open: lock screen, state every 15 seconds via the ``PositionReporter``,
/// reading time in the log.
///
/// **What is decided differently without a sheet:** if the library asks about the state
/// (``LibraryService/decide(for:)`` returning `.question`) because the listening position
/// here and on the server differ, nobody is there to answer. The local state then wins
/// (``Resolution/take(_:supply:)``), the one the widget showed and the user pressed on,
/// and the server keeps its own; when the sheet is next opened there is no question any
/// more, because the book is already in the player.
@MainActor
struct AudiobookStarter {

    let player: Player
    let stock: StockService
    let reader: ReadCall
    let inventory: LibraryService
    let readingTime: ReadingTimeLog
    let settings: UserDefaults
    let transport: @Sendable (Provider) -> any Transport
    /// The long edge of the cover for the lock screen, in pixels.
    let coverEdge: Int

    /// The edge for 600 pt: the sheet passes its scale, the core takes the device's (without
    /// a window UIKit reports 0, and then 3 applies, as on every iPhone since the X).
    static func coverEdge(displayScale: CGFloat) -> Int {
        Int(600 * (displayScale > 0 ? displayScale : 3))
    }

    /// The sheet's path: the title's source, the volume from the store or from the
    /// server, the position from the state (second, otherwise share times duration), an
    /// `AudioPlayer/Audiobook` with cover and callback, into the player, and
    /// ``ReadCall/ongoing`` set so the mini player can reopen the sheet. Does not play yet.
    func load(_ title: Title, start: ReadingState?) async throws {
        guard let source = inventory.source(title.identifier.source),
            case .audioStream(let fetch) = source.content(title)
        else {
            throw SourceError.notPossible(title.identifier.source, "no audio stream")
        }
        let volume: AudioManifest
        if let local = stock.audioManifest(title.identifier) {
            volume = local
        } else {
            volume = try await fetch()
        }
        let second: TimeInterval =
            if case .second(let s, _)? = start?.position { s } else {
                (start?.fraction ?? 0) * volume.duration
            }
        let reporter = PositionReporter()
        reporter.inventory = inventory
        reporter.log = readingTime
        reporter.settings = settings
        let identifier = title.identifier
        let duration = volume.duration
        let cover = title.cover
        let headerLines = source.headerLines()
        let imageTransport = transport(identifier.source.provider)
        let edge = coverEdge
        let reader = reader
        var toSeries: (@MainActor @Sendable () -> Void)?
        if let series = title.series {
            let target = Target.series(series.identifier)
            toSeries = { reader.jump(to: target) }
        }
        let audiobook = Audiobook(
            id: identifier.description, name: title.name, subline: title.authors.first,
            narrator: title.narrator.first, volume: volume, headerLines: headerLines,
            transport: imageTransport,
            start: second,
            image: {
                guard let cover else { return nil }
                return await ImageLoader.shared.image(
                    cover, headerLines: headerLines, pixels: edge, transport: imageTransport)
            },
            report: { second, done in
                reporter.report(.second(second, from: duration), for: identifier, completed: done)
            },
            toSeries: toSeries)
        try await player.load(audiobook)
        reader.ongoing = title
    }

    /// The path without a sheet: find the title on the shelf (from persistence if the
    /// shelf is still empty, otherwise after a refresh), decide the state, load, play. If
    /// exactly this audiobook is already in the player, it just continues.
    ///
    /// - Throws: ``SourcesKit/SourceError/notFound(_:)`` if no account of the profile
    ///   knows the title; otherwise whatever source or player throw.
    func launch(_ identifier: TitleID) async throws {
        if player.audiobook?.id == identifier.description {
            player.play()
            return
        }
        let title = try await find(identifier)
        let resolution = await inventory.decide(for: identifier)
        try await load(title, start: resolution.state)
        player.play()
        Diagnostics.step("Audiobook started without sheet: \(title.name)", since: nil, area: "Player")
    }

    /// First persistence (milliseconds, as when opening the app), then the sources; and
    /// if someone else is refreshing right now (the shell at launch), the starter waits
    /// for its result instead of failing with an empty shelf.
    private func find(_ identifier: TitleID) async throws -> Title {
        if !inventory.storeRead { await inventory.fromStore() }
        if let title = inventory.title(identifier) { return title }
        await inventory.refresh()
        while inventory.refreshing { try await Task.sleep(for: .milliseconds(50)) }
        guard let title = inventory.title(identifier) else { throw SourceError.notFound(identifier) }
        return title
    }

    /// The decision of the widget button: if the audiobook is in the player it toggles;
    /// otherwise it loads and plays it. `false` if the link is not an audiobook link or
    /// loading failed; the reason is in the log.
    func switchTo(identifier: String, link: URL) async -> Bool {
        if player.audiobook?.id == identifier {
            player.switchTo()
            return true
        }
        guard case .read(let titleIdentifier)? = Deeplink(link) else {
            Diagnostics.network.error(
                "Widget button: not an audiobook link: \(link.absoluteString, privacy: .public)")
            return false
        }
        do {
            try await launch(titleIdentifier)
            return true
        } catch {
            Diagnostics.network.error(
                "Widget button: audiobook not started: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
