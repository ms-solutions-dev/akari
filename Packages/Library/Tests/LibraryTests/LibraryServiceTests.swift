import Foundation
import Observation
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// The service against mocks: store first, network after, write optimistically.
/// Each test gets its own folder and cleans it up.
@Suite("Library service")
@MainActor
struct LibraryServiceTests {

    /// A registry that may change on the way — like the real one when signing out.
    @MainActor
    private final class Register {
        var sources: [MockSource]
        init(_ sources: [MockSource]) { self.sources = sources }
    }

    private func persistence() -> LibraryStore {
        LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "bestand-\(UUID().uuidString)"))
    }

    /// Counts how often an observation fires.
    @MainActor
    private final class Trigger {
        var count = 0
    }

    /// **The loop:** if only a full genre answer counted as remembered, every
    /// empty one asked anew at once, the answer went into an observed value, the shell rebuilt
    /// and asked again — 100 % CPU at idle. An empty catalog may report at most once
    /// that it has answered.
    @Test("Empty genres and authors do not keep asking", arguments: ["genres", "autoren"])
    func emptyAnswerRemembered(_ was: String) async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let service = LibraryService(persistence: persistence) { [] }
        // Ten rounds like ten rebuilds of the shell: each asks and checks whether the answer
        // changes the value again. Before the fix every round reported a change.
        let trigger = Trigger()
        for _ in 0..<10 {
            withObservationTracking {
                if was == "genres" { _ = service.genres() } else { _ = service.authors() }
            } onChange: {
                Task { @MainActor in trigger.count += 1 }
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(trigger.count <= 1, "\(trigger.count) rebuilds without a change to the library")
    }

    @Test("Refreshing fills the catalog; a reading state follows, signing out removes the source")
    func catalog() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let register = Register(MockShelf.base())
        let service = LibraryService(persistence: persistence) { register.sources }
        await service.refresh()
        let catalog = try #require(service.catalog)
        #expect(try catalog.count(CatalogQuery()) == service.shelf.allTitles.count)
        let band48 = try #require(service.shelf.allTitles.first { $0.name == "Pepper&Carrot 38" })
        try await service.set(.read, for: band48.identifier)
        var read = CatalogQuery()
        read.phase = .read
        read.onlyIdentifiers = [[band48.identifier.description]]
        for _ in 0..<50 where try catalog.count(read) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try catalog.count(read) == 1, "der Stand kommt im Katalog an")
        let route = register.sources.removeFirst()
        await service.refresh()
        #expect(try catalog.identifiers(source: route.identifier).isEmpty)
    }

    @Test("Kept titles without a catalog still stand on the shelf — and not twice if the catalog has them")
    func keptWithoutCatalog() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let register = Register(MockShelf.base())
        let service = LibraryService(persistence: persistence) { register.sources }
        await service.refresh()
        let known = try #require(service.shelf.allTitles.first)
        let fremd = Title(
            identifier: TitleID(source: known.identifier.source, id: "nur-im-vorrat"), kind: .book,
            name: "Nur im Vorrat", summary: "Ein Klappentext, der lang genug ist.")
        service.stockTitle = [known, fremd]
        #expect(service.shelf.title(fremd.identifier)?.name == "Nur im Vorrat")
        #expect(
            service.shelf.allTitles.filter { $0.identifier == known.identifier }.count == 1, "nicht doppelt")
        // Refreshing replaces the catalogs — what is kept stays.
        await service.refresh()
        #expect(service.shelf.title(fremd.identifier) != nil)
        // Account signed out: the catalog drops, what is kept of the source stays visible.
        register.sources.removeAll { $0.identifier == known.identifier.source }
        await service.refresh()
        #expect(service.shelf.title(fremd.identifier) != nil)
        #expect(service.shelf.title(known.identifier) != nil, "auch der, den nur noch der Vorrat kennt")
        // The store never gets a supplemented extract.
        await service.secureStore()
        #expect(persistence.loadExtract(known.identifier.source) == nil)
    }

    @Test("Refreshing asks all sources side by side and stores every extract")
    func refresh() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence) { sources }
        #expect(service.shelf.empty)
        await service.refresh()
        #expect(service.shelf.kinds == [.manga, .book, .audiobook])
        #expect(service.failure.isEmpty)
        #expect(service.renewed != nil)
        #expect(!service.fromCache)
        for q in sources { #expect(persistence.loadExtract(q.identifier) != nil) }
        #expect(sources.map(\.fetches) == [1, 1, 1])
    }

    @Test("Offline: launch stands from the store, the silent source keeps its old extract")
    func offline() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let first = MockShelf.base()
        await LibraryService(persistence: persistence) { first }.refresh()

        let second = MockShelf.base()
        second[0].set(network: .unreachable)
        let service = LibraryService(persistence: persistence) { second }
        await service.fromStore()
        #expect(service.shelf.kinds == [.manga, .book, .audiobook])
        #expect(service.fromCache)
        #expect(service.shelf.continueReading.count == 4)

        await service.refresh()
        #expect(service.failure[second[0].identifier] == .unreachable(second[0].identifier))
        #expect(service.shelf.kinds == [.manga, .book, .audiobook], "Komga stays from the store")
        #expect(!service.fromCache, "zwei haben geantwortet")
    }

    @Test("With downloads on the shelf, launch still reads the store")
    func storeDespiteStock() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let first = MockShelf.base()
        let previously = LibraryService(persistence: persistence) { first }
        await previously.refresh()
        let keep = try #require(previously.shelf.allTitles.first)

        let service = LibraryService(persistence: persistence) { MockShelf.base() }
        // As on launch: the offline store reports its titles before the store is read.
        service.stockTitle = [keep]
        #expect(!service.shelf.empty, "die heruntergeladenen Titel stehen schon da")
        #expect(!service.storeRead)
        await service.fromStore()
        #expect(service.storeRead)
        #expect(service.shelf.continueReading.count == 4, "die Lesestände aus der Ablage sind da")
        #expect(service.shelf.kinds == [.manga, .book, .audiobook])
    }

    @Test("A signed-out account drops from the shelf and from the store")
    func signedOut() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let register = Register(MockShelf.base())
        let service = LibraryService(persistence: persistence) { register.sources }
        await service.refresh()
        let grimmory = register.sources.remove(at: 1)
        await service.refresh()
        #expect(service.shelf.kinds == [.manga, .audiobook])
        #expect(persistence.loadExtract(grimmory.identifier) == nil)
    }

    @Test("Setting read status: Read writes the end, Unread forgets — the shelf shows it at once")
    func readStatus() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence) { sources }
        await service.refresh()
        let band48 = try #require(service.shelf.allTitles.first { $0.name == "Pepper&Carrot 38" })
        try await service.set(.read, for: band48.identifier)
        #expect(service.shelf.readingState(band48.identifier)?.completed == true)
        #expect(sources[0].written.last?.1.position == .page(201, from: 201))
        // A reading state is written bundled — only after the quiet period or on securing.
        #expect(
            persistence.loadExtract(sources[0].identifier)?.readingStates[band48.identifier]?.completed
                != true)
        await service.secureStore()
        #expect(
            persistence.loadExtract(sources[0].identifier)?.readingStates[band48.identifier]?.completed
                == true)

        try await service.set(.started, for: band48.identifier)
        #expect(service.shelf.readingState(band48.identifier)?.position == .page(1, from: 201))

        try await service.set(.unread, for: band48.identifier)
        #expect(service.shelf.readingState(band48.identifier) == nil)
        #expect(try await sources[0].progress(band48.identifier) == nil)

        let audiobook = try #require(service.shelf.allTitles.first { $0.name == "Treasure Island" })
        try await service.set(.read, for: audiobook.identifier)
        #expect(sources[2].written.last?.1.position == .second(41_500, from: 41_500))
    }

    @Test("If the server is unreachable, the new state stays and is queued")
    func rolledBack() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        let band47 = try #require(service.shelf.allTitles.first { $0.name == "Pepper&Carrot 37" })
        sources[0].set(network: .unreachable)
        try await service.set(.read, for: band47.identifier)
        #expect(service.shelf.readingState(band47.identifier)?.completed == true)
        #expect(service.pending == 1)
        #expect(sources[0].written.isEmpty)
    }

    /// Device reports 02.11.: right after the last source answered, the main thread hung for
    /// 103–144 ms — the pending states were laid on with `with`, which starts an empty memo, and
    /// the start rows were recomputed over the whole catalog at the next draw.
    @Test("Pending states over a new shelf: the start rows come precomputed")
    func pendingKeepsPrecompute() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        let band47 = try #require(service.shelf.allTitles.first { $0.name == "Pepper&Carrot 37" })
        sources[0].set(network: .unreachable)
        try await service.set(.read, for: band47.identifier)
        #expect(service.pending == 1)

        let fresh = Shelf(
            extracts: service.shelf.extracts, capabilities: service.shelf.capabilities,
            keep: service.shelf.keep, saved: service.shelf.saved,
            bookSeriesList: service.shelf.bookSeriesList, maxAge: service.shelf.maxAge)
        let laid = await service.withPending(fresh)
        #expect(laid.readingState(band47.identifier)?.completed == true)
        for row in ["weiterlesen", "neuImRegal"] {
            #expect(laid.memo.holds(row), "\(row) precomputed off the main thread")
        }
    }

    /// While a fullscreen reader is open, the reading state does not change the observed shelf —
    /// the server gets it at once anyway, and whoever asks sees it.
    @Test("Retained reading states: server at once, shelf only on closing")
    func holdBack() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        let manga = try #require(service.shelf.allTitles.first { $0.kind == .manga })
        let previously = service.shelf.readingState(manga.identifier)
        let trigger = Trigger()
        withObservationTracking {
            _ = service.shelf
        } onChange: {
            Task { @MainActor in trigger.count += 1 }
        }
        service.holdsBack = true
        let state = ReadingState(position: .page(37, from: 200), timestamp: Date())
        try await service.write(state, for: manga.identifier)
        try await Task.sleep(for: .milliseconds(50))
        // The shelf stayed quiet, the state is there anyway — for reader and server.
        #expect(trigger.count == 0)
        #expect(service.shelf.readingState(manga.identifier) == previously)
        #expect(service.readingState(manga.identifier)?.position == state.position)
        #expect(sources.contains { !$0.written.isEmpty })
        // On closing it goes onto the shelf.
        service.holdsBack = false
        #expect(service.shelf.readingState(manga.identifier)?.position == state.position)
    }

    /// The app is quit while the reader is open: what was retained must still
    /// stand in the store — otherwise the next launch resubmits the old state to the server.
    @Test("Retained states survive quitting with the reader open")
    func retainedSecured() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        let manga = try #require(service.shelf.allTitles.first { $0.kind == .manga })
        service.holdsBack = true
        let state = ReadingState(position: .page(37, from: 200), timestamp: Date())
        try await service.write(state, for: manga.identifier)
        // Into the background — the reader is still open, `retained` stays on.
        await service.secureStore()
        // New launch: a fresh service reads only the store.
        let after = LibraryService(persistence: persistence, queue: Queue(folder: nil)) {
            MockShelf.base()
        }
        await after.fromStore()
        #expect(after.shelf.readingState(manga.identifier)?.position == state.position)
    }

    /// The slim overview (without reading titles) must say exactly what the full content says.
    @Test("Collection overview: same count and same kinds as the full content")
    func collectionOverview() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        #expect(!service.shelf.collections.isEmpty)
        for s in service.shelf.collections {
            let full = service.entries(in: s)
            let short = service.overview(in: s)
            #expect(short.count == full.count, "\(s.name)")
            #expect(short.kinds == Set(full.map(\.kind)), "\(s.name)")
        }
    }

    @Test("An audiobook without server: the second stays here and is queued")
    func audiobookWithoutNetwork() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        let audiobook = try #require(service.shelf.allTitles.first { $0.kind == .audiobook })
        sources[2].set(network: .unreachable)
        let state = ReadingState(position: .second(1_234, from: 38_000), timestamp: Date())
        try await service.write(state, for: audiobook.identifier)
        #expect(service.shelf.readingState(audiobook.identifier)?.position == state.position)
        #expect(service.pending == 1)
        #expect(service.queue.pending(audiobook.identifier)?.state?.position == state.position)
        #expect(sources[2].written.isEmpty)
        // Before the player: the server does not answer — the local state holds, no conflict,
        // and it stays scheduled for resubmitting.
        guard case .take(let taken, supply: true) = await service.decide(for: audiobook.identifier)
        else {
            Issue.record("den hiesigen Stand erwartet")
            return
        }
        #expect(taken.position == state.position)
        // Network back: resubmitted, the queue is empty.
        sources[2].set(network: .reachable)
        await service.supply()
        #expect(service.pending == 0)
        #expect(sources[2].written.count == 1)
    }

    @Test("All read: volume by volume, those already read skipped")
    func allRead() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence) { sources }
        await service.refresh()
        let bookSeries = try #require(service.shelf.allSeries.first { $0.name == "Pepper&Carrot" })
        try await service.allRead(bookSeries.identifier)
        #expect(sources[0].written.count == 2, "46 war schon gelesen")
        #expect(service.shelf.seriesState(bookSeries.identifier).completed)
    }
}

/// Saving via the service: list first, Grimmory mirrored, Komga only in the app.
@Suite("Library service · Saving")
@MainActor
struct LibraryServiceSaveTests {

    private func savedList() -> SavedList {
        let name = "merken-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SavedList(persistence: defaults, cloud: nil)
    }

    private func persistence() -> LibraryStore {
        LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "bestand-\(UUID().uuidString)"))
    }

    @Test(
        "Grimmory titles land on the “Favorites” shelf, Komga titles only in the list; the shelf follows at once"
    )
    func spiegel() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, savedList: savedList()) { sources }
        await service.refresh()
        let book = try await sources[1].library().title[2].identifier
        let volume = try await sources[0].library().title[0].identifier
        try await service.save(.title(book), saved: true)
        try await service.save(.title(volume), saved: true)
        #expect(sources[1].saved == [book])
        #expect(sources[0].saved.isEmpty)
        #expect(service.shelf.savedEntries.count == 2)
        #expect(service.shelf.saved.first == .title(book))
        try await service.save(.title(book), saved: false)
        #expect(sources[1].saved.isEmpty)
        #expect(service.shelf.savedEntries.map(\.kind) == [.manga])
    }

    @Test("If Grimmory refuses, the list is back as before")
    func rollback() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, savedList: savedList()) { sources }
        await service.refresh()
        let book = try await sources[1].library().title[2].identifier
        sources[1].set(network: .unreachable)
        await #expect(throws: SourceError.unreachable(sources[1].identifier)) {
            try await service.save(.title(book), saved: true)
        }
        #expect(service.shelf.saved.isEmpty)
        #expect(service.savedList.entries.isEmpty)
    }

    @Test("On refresh, for Grimmory what the server has saved holds")
    func sync() async throws {
        let persistence = persistence()
        defer { persistence.clearOut() }
        let sources = MockShelf.base()
        let books = try await sources[1].library().title
        sources[1].saved = [books[0].identifier]
        let list = savedList()
        list.save(.title(books[1].identifier))
        let service = LibraryService(persistence: persistence, savedList: list) { sources }
        await service.refresh()
        #expect(service.shelf.saved == [.title(books[0].identifier)])
    }
}

/// Collections via the service: fetched on refresh, arranging optimistic.
@Suite("Library service · Collections")
@MainActor
struct LibraryServiceCollectionsTests {

    private func service(_ sources: [MockSource]) -> LibraryService {
        let name = "sammlungen-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return LibraryService(
            persistence: LibraryStore(
                folder: FileManager.default.temporaryDirectory.appending(path: "bestand-\(UUID().uuidString)")
            ),
            savedList: SavedList(persistence: defaults, cloud: nil), settings: defaults
        ) { sources }
    }

    @Test("Refreshing brings the collections along; arranging writes to the server and rolls back on refusal")
    func arrange() async throws {
        let sources = MockShelf.base()
        let d = service(sources)
        await d.refresh()
        #expect(d.shelf.collections.map(\.name) == ["Summer Reading"])
        let s = d.shelf.collections[0]
        let holmes = try await sources[1].library().title[0].identifier
        try await d.arrange(.title(holmes), in: s.identifier, into: true)
        #expect(d.shelf.collection(s.identifier)?.entries.count == 2)
        #expect(sources[1].collectionList[0].entries.count == 2)
        sources[1].set(network: .unreachable)
        await #expect(throws: SourceError.self) {
            try await d.arrange(.title(holmes), in: s.identifier, into: false)
        }
        #expect(d.shelf.collection(s.identifier)?.entries.count == 2, "zurückgenommen")
    }

    @Test("Creating a new collection puts the target in; the series choice survives a restart")
    func createAndSeriesChoice() async throws {
        let sources = MockShelf.base()
        let d = service(sources)
        await d.refresh()
        let frankenstein = try await sources[1].library().title[2].identifier
        try await d.create(collection: "Vacation", for: .title(frankenstein), collectionKind: .shelf)
        #expect(d.shelf.collections.map(\.name) == ["Summer Reading", "Vacation"])
        #expect(d.shelf.collections[1].contains(.title(frankenstein)))
        #expect(d.bookSeriesList == Shelf.bookSeriesDefault)
        #expect(d.shelf.entries(.book).count == 2, "Sherlock Holmes gebündelt")
        d.bookSeriesList = []
        #expect(d.shelf.entries(.book).count == 3)
    }
}

@Suite("Deadline on opening")
struct FristTests {
    @Test("A server that does not answer holds up opening no longer than the deadline")
    func frist() async throws {
        let clock = ContinuousClock()
        let startTime = clock.now
        await #expect(throws: LibraryService.DeadlineExpired.self) {
            try await LibraryService.withDeadline(.milliseconds(100)) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        #expect(clock.now - startTime < .seconds(1))
        let fast = try await LibraryService.withDeadline(.seconds(2)) { 7 }
        #expect(fast == 7)
    }
}

@Suite("Store core")
struct StoreCoreTests {
    @Test("Large sources get a small core with readings, new items and their series")
    func core() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kern-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = LibraryStore(folder: folder)
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let bookSeries = SeriesID(source: source, id: "r1")
        let title = (0..<5_000).map { (i: Int) -> Title in
            let reference: SeriesReference? =
                i < 3 ? SeriesReference(identifier: bookSeries, name: "Reihe", volume: Double(i + 1)) : nil
            let date = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i))
            return Title(
                identifier: TitleID(source: source, id: "\(i)"), kind: .book, name: "Buch \(i)",
                series: reference,
                added: date)
        }
        let read = TitleID(source: source, id: "1")
        let extract = LibraryExtract(
            source: source,
            seriesList: [Series(identifier: bookSeries, kind: .book, name: "Reihe", volumeCount: 3)],
            title: title,
            readingStates: [read: ReadingState(position: .fraction(0.4), timestamp: Date())], state: Date())
        try persistence.write(extract)
        let core = try #require(persistence.readCore(source))
        #expect(core.title.count == 200 + 3, "200 jüngste und die drei Bände der Reihe mit dem Stand")
        #expect(core.readingStates[read] != nil)
        #expect(core.seriesList.map(\.identifier) == [bookSeries])
        #expect(persistence.loadExtract(source)?.title.count == 5_000, "der ganze Auszug bleibt")
        let small = LibraryExtract(source: source, title: Array(title.prefix(10)), state: Date())
        try persistence.write(small)
        #expect(persistence.readCore(source) == nil, "kleine Quellen liest man ganz")
    }
}
