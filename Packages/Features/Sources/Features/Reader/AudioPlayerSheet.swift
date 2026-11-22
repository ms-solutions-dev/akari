import AccountsKit
import AudioPlayer
import Bedrock
import DesignSystem
import Library
import NetworkLocation
import OfflineStore
import ReadingProgress
import SourcesKit
import SwiftUI

/// The bridge from the library to the player: asks the server for the state (conflict sheet
/// as with the readers) and lets the `AudiobookStarter` fetch tracks and chapters, build the
/// `Audiobook` and put it into the shell's player. The sheet then shows only
/// `AudioPlayerView`; when it closes, the sound keeps playing. The path lives in the
/// starter because the widget button must take it without a sheet.
///
/// If the audiobook is kept on the device, the volume comes from the offline store (tracks
/// as files, chapters as from the server) and the server is asked only for the state; if it
/// does not answer, the local one wins (`LibraryService.decide(for:)`) and what is listened
/// to goes into the queue. So it also plays on a plane.
struct AudioPlayerSheet: View {

    let title: Title

    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock
    @Environment(Player.self) private var player
    @Environment(ReadCall.self) private var reader
    @Environment(\.imageTransport) private var transport
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismissSheet
    @Environment(\.closePlayer) private var closeAction
    @Environment(ReadingTimeLog.self) private var readingTime
    @Environment(\.profileSettings) private var settings
    @State private var resolution: Resolution?
    @State private var conflict: (here: ReadingState, there: ReadingState)?
    @State private var failure: SourceError?
    @State private var ready = false

    var body: some View {
        ZStack {
            if ready {
                AudioPlayerView(player: player)
            } else if let failure {
                FetchFailureView(lookupKey: "player.notFetched", failure: failure) {
                    self.failure = nil
                    Task { await load(start: resolution?.state) }
                } close: {
                    close()
                }
            } else {
                VStack(spacing: 16) {
                    Cover(title, width: 140)
                    Text(verbatim: title.name)
                        .font(Typography.title(.title3))
                        .multilineTextAlignment(.center)
                    ProgressView()
                }
                .padding(32)
            }
        }
        .paper()
        .task {
            // If it is already in the player, just show it: no second state, no jump.
            if player.audiobook?.id == title.identifier.description {
                ready = true
                return
            }
            guard resolution == nil else { return }
            let e = await inventory.decide(for: title.identifier)
            if case .question(let here, let there) = e {
                Haptics.warning()
                conflict = (here, there)
            } else {
                resolution = e
                await load(start: e.state)
            }
        }
        .conflictSheet(conflict, title: title) { choice in
            guard let conflict else { return }
            let state: ReadingState
            switch choice {
            case .there:
                inventory.adopt(conflict.there, for: title.identifier)
                state = conflict.there
            case .here:
                state = conflict.here
                Task { await inventory.retain(at: conflict.here, for: title.identifier) }
            }
            resolution = .take(state, supply: choice == .here)
            self.conflict = nil
            Task { await load(start: state) }
        }
        .readingHandoff(title)
    }

    /// As a layer of the shell (player layer) it closes that layer's action, otherwise `dismiss`.
    private func close() {
        if let closeAction { closeAction() } else { dismissSheet() }
    }

    /// The starter from the sheet's environment: the same path as without a sheet.
    private var starter: AudiobookStarter {
        AudiobookStarter(
            player: player, stock: stock, reader: reader, inventory: inventory, readingTime: readingTime,
            settings: settings, transport: transport,
            coverEdge: AudiobookStarter.coverEdge(displayScale: displayScale))
    }

    private func load(start: ReadingState?) async {
        do {
            try await starter.load(title, start: start)
            ready = true
            player.play()
        } catch let failure as SourceError {
            self.failure = failure
        } catch {
            Diagnostics.network.error("Audiobook not loaded: \(String(describing: error), privacy: .public)")
            failure = .onFetch(error, source: title.identifier.source, title: title.identifier)
        }
    }
}
