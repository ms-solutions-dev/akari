import Foundation
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// The outage pass: store first when only one source is missing — with
/// its state for the banner —, a 502 takes the same path as "off", and the
/// resubmit says how much arrived.
@Suite("Library: outages")
@MainActor
struct LibraryOutageTests {

    private func persistence() -> LibraryStore {
        LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "stoerung-\(UUID().uuidString)"))
    }

    @Test("Komga off: launch from the store, the source's state is that of its extract, the others fresh")
    func komgaAus() async throws {
        let persistence = persistence()
        let sources = MockShelf.base()
        let first = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await first.refresh()

        sources[0].set(network: .unreachable)
        let second = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await second.fromStore()
        #expect(second.shelf.allTitles.filter { $0.kind == .manga }.count == 3, "manga from the store")
        #expect(second.fromCache)
        await second.refresh()
        #expect(second.shelf.allTitles.filter { $0.kind == .manga }.count == 3, "the old extract stays")
        #expect(second.failure[sources[0].identifier] == .unreachable(sources[0].identifier))
        #expect(second.failure.count == 1)
        #expect(!second.fromCache, "two sources answered")
        #expect(second.shelf.state(sources[0].identifier) == MockShelf.state)
        #expect(second.shelf.state(SourceID(provider: .opds, server: "x")) == nil)
    }

    @Test("502 takes the same path as “off”: old extract stays, the error is the server outage")
    func serverDisruption() async throws {
        let persistence = persistence()
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        sources[0].set(disruption: .serverDisruption(sources[0].identifier, status: 502))
        await service.refresh()
        #expect(service.shelf.allTitles.filter { $0.kind == .manga }.count == 3)
        #expect(
            service.failure[sources[0].identifier] == .serverDisruption(sources[0].identifier, status: 502))
        // A state for the failed source stays here and waits — not definitive.
        let volume = service.shelf.allTitles.first { $0.kind == .manga }!
        try await service.write(
            ReadingState(position: .page(9, from: 198), timestamp: Date()), for: volume.identifier)
        #expect(service.pending == 1)
        #expect(service.shelf.readingState(volume.identifier)?.position == .page(9, from: 198))
    }

    @Test("Resubmitting reports how many states arrived — and when")
    func supplied() async throws {
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence(), queue: Queue(folder: nil)) { sources }
        await service.refresh()
        #expect(service.supplied == nil)
        for q in sources { q.set(network: .unreachable) }
        let volume = service.shelf.allTitles.first { $0.kind == .manga }!
        let book = service.shelf.allTitles.first { $0.kind == .book }!
        try await service.write(
            ReadingState(position: .page(90, from: 198), timestamp: Date()), for: volume.identifier)
        try await service.write(
            ReadingState(position: .fraction(0.6), timestamp: Date()), for: book.identifier)
        #expect(service.pending == 2)
        await service.supply()
        #expect(service.supplied == nil, "ohne Netz kommt nichts an")
        for q in sources { q.set(network: .reachable) }
        await service.supply()
        #expect(service.pending == 0)
        #expect(service.supplied?.count == 2)
        #expect(abs((service.supplied?.around ?? .distantPast).timeIntervalSinceNow) < 5)
    }
}
