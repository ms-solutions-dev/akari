import AudioPlayer
import Foundation
import Library
import OfflineStore
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import Testing
import WidgetBridge

@testable import Features

/// A test rig without the shell: the audiobook mock as the only source, a library with an
/// empty store under `tmp`, an offline store, a player, and a transport that answers every
/// track with a minute of sound so the player reports nothing as failed.
/// Cleaned up at the end.
@MainActor
final class StarterState {
    let folder: URL
    let source: MockSource
    let transport: MockTransport
    let inventory: LibraryService
    let stock: StockService
    let player = Player()
    let reader = ReadCall()
    let settings: UserDefaults
    let identifier: String

    init() {
        identifier = UUID().uuidString
        folder = FileManager.default.temporaryDirectory.appending(path: "starter-\(identifier)")
        settings = UserDefaults(suiteName: "starter-\(identifier)")!
        source = MockShelf.audiobookshelf()
        transport = MockTransport()
        transport.answer(
            "GET", "/api/items/*",
            with: .init(data: MockSound.wav(), headerLines: ["Content-Type": "audio/wav"]))
        let source = source
        inventory = LibraryService(
            persistence: LibraryStore(folder: folder.appending(path: "bestand")),
            savedList: SavedList(persistence: settings, cloud: nil), settings: settings,
            queue: Queue(folder: nil)
        ) { [source] }
        stock = StockService(persistence: KeepStore(folder: folder.appending(path: "vorrat")))
    }

    var starter: AudiobookStarter {
        let transport = transport
        return AudiobookStarter(
            player: player, stock: stock, reader: reader, inventory: inventory,
            readingTime: ReadingTimeLog(file: nil),
            settings: settings, transport: { _ in transport }, coverEdge: 600)
    }

    /// "The Time Machine" with state 176 s on the "server".
    var opener: Title { source.extract.title[0] }

    func tidyUp() {
        player.close()
        try? FileManager.default.removeItem(at: folder)
        settings.removePersistentDomain(forName: "starter-\(identifier)")
    }
}

/// The audiobook starter: loads and plays without the shell, handles
/// the widget button, and says no where it can do nothing.
@Suite("Audiobook starter without the shell")
@MainActor
struct AudiobookStarterTests {

    @Test("Empty shelf, no store: the starter asks the source, loads and plays from the state")
    func startWithoutShell() async throws {
        let state = StarterState()
        defer { state.tidyUp() }
        #expect(state.inventory.shelf.empty)
        try await state.starter.launch(state.opener.identifier)
        #expect(state.player.audiobook?.id == state.opener.identifier.description)
        #expect(state.player.running)
        #expect(state.player.time == 176, "the state from the server, not from the start")
        #expect(state.player.audiobook?.volume.tracks.count == 634, "38,000 s in one-minute tracks")
        #expect(
            state.reader.ongoing?.identifier == state.opener.identifier,
            "the mini player can open the sheet")
        #expect(
            !state.inventory.shelf.empty, "the shelf is there afterwards, the shell does not load it again")
    }

    @Test("The button: not in the player, load and play; in the player, pause, then play again")
    func switchTo() async throws {
        let state = StarterState()
        defer { state.tidyUp() }
        let identifier = state.opener.identifier
        let link = Deeplink.read(identifier).url
        #expect(await state.starter.switchTo(identifier: identifier.description, link: link))
        #expect(state.player.audiobook?.id == identifier.description)
        #expect(state.player.running)
        #expect(await state.starter.switchTo(identifier: identifier.description, link: link))
        #expect(!state.player.running, "second press: pause")
        #expect(state.player.audiobook?.id == identifier.description, "and the book stays loaded")
        #expect(await state.starter.switchTo(identifier: identifier.description, link: link))
        #expect(state.player.running, "third press: resume")
    }

    @Test("If exactly this book is already in the player, `start` only resumes, with no second load")
    func startTwice() async throws {
        let state = StarterState()
        defer { state.tidyUp() }
        try await state.starter.launch(state.opener.identifier)
        state.player.pause()
        state.player.jump(to: 500, shouldReport: false)
        try await state.starter.launch(state.opener.identifier)
        #expect(state.player.running)
        #expect(state.player.time == 500, "the position stays, not from the saved state again")
    }

    @Test("The error path: unknown title, foreign link, source unreachable, no, player empty")
    func errorPath() async throws {
        let state = StarterState()
        defer { state.tidyUp() }
        let foreign = TitleID(source: state.opener.identifier.source, id: "gibtsnicht")
        #expect(
            await !state.starter.switchTo(identifier: foreign.description, link: Deeplink.read(foreign).url))
        #expect(await !state.starter.switchTo(identifier: "x", link: Deeplink.statistics.url))
        await #expect(throws: SourceError.notFound(foreign)) { try await state.starter.launch(foreign) }
        // A fresh state: the first failed attempt already filled the shelf from the source;
        // here it should stay silent before anyone asks (no cache).
        let cold = StarterState()
        defer { cold.tidyUp() }
        cold.source.set(network: .unreachable)
        let identifier = cold.opener.identifier
        #expect(
            await !cold.starter.switchTo(
                identifier: identifier.description, link: Deeplink.read(identifier).url))
        #expect(cold.player.audiobook == nil)
        #expect(cold.reader.ongoing == nil)
    }

    @Test("Cold start from the widget: the title comes from the store, even if the server is silent")
    func fromStore() async throws {
        let state = StarterState()
        defer { state.tidyUp() }
        try LibraryStore(folder: state.folder.appending(path: "bestand")).write(state.source.extract)
        state.source.set(network: .unreachable)
        try await state.starter.launch(state.opener.identifier)
        #expect(state.player.audiobook?.id == state.opener.identifier.description)
        #expect(state.player.running)
        #expect(state.player.time == 176, "the state from the store")
    }
}

/// The core as a whole: the widget button's path from the switch to the snapshot,
/// without the shell, with a profile registry without keychain.
@Suite("The app core and the widget button")
@MainActor
struct AppCoreTests {

    @Test("Switch assigned, button pressed: loaded, played, snapshot 'running'; once more: pause")
    func buttonUntilSnapshot() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let source = MockShelf.audiobookshelf()
        let transport = MockTransport()
        transport.answer(
            "GET", "/api/items/*",
            with: .init(data: MockSound.wav(), headerLines: ["Content-Type": "audio/wav"]))
        let folder = state.root.appending(path: "weiterhoeren")
        let core = AppCore(
            profiles: state.profiles,
            context: { profile, persistence, device in
                state.context(profile, persistence, device, sources: { [source] })
            },
            device: state.device, preview: true,
            listenSnapshot: ContinueListeningWriter(folder: folder))
        defer { core.player.close() }
        core.assignContinueListeningSwitch()
        let switchTo = try #require(ContinueListeningSwitch.switchTo)
        let identifier = source.extract.title[0].identifier
        let link = Deeplink.read(identifier).url

        #expect(await switchTo(identifier.description, link))
        #expect(core.player.audiobook?.id == identifier.description)
        #expect(core.player.running)
        let s1 = try #require(SnapshotStore.readContinueListening(from: folder))
        #expect(s1.audiobook?.id == identifier.description)
        #expect(s1.audiobook?.running == true)
        #expect(s1.audiobook?.chapter == "Chapter 1")
        #expect(s1.audiobook?.time == 176)

        #expect(await switchTo(identifier.description, link))
        #expect(!core.player.running)
        let s2 = try #require(SnapshotStore.readContinueListening(from: folder))
        #expect(s2.audiobook?.running == false, "the widget shows Play right after the intent")

        // Foreign book: no, and the snapshot stays with the loaded book.
        let foreign = TitleID(source: identifier.source, id: "nix")
        #expect(await !switchTo(foreign.description, Deeplink.read(foreign).url))
        #expect(SnapshotStore.readContinueListening(from: folder)?.audiobook?.id == identifier.description)
    }

    @Test("Profile switch in the core: player closed, context new, the starter sees the new profile")
    func profileSwitch() throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        var built: [Int] = []
        let core = AppCore(
            profiles: state.profiles,
            context: { profile, persistence, device in
                built.append(profile.id)
                return state.context(profile, persistence, device)
            }, device: state.device, preview: true)
        #expect(built == [1])
        let spouse = try state.profiles.create(to: "Sam", color: "pflaume")
        core.switchTo(to: spouse)
        #expect(built == [1, spouse.id])
        #expect(core.context.profile.id == spouse.id)
        #expect(core.audiobookStarter.inventory === core.context.inventory)
        core.switchTo(to: spouse)
        #expect(built == [1, spouse.id], "the same profile again builds nothing")
    }
}
