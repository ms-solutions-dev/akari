import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

/// Three mocks flow through the protocol, and what the UI needs from them — segment,
/// counters, "Continue reading", keep button — can be computed without anyone asking
/// the provider. The computing itself lives in the library; here it stands in its
/// shortest form, as proof that the model holds.
@Suite("Mocks through the slot")
struct MockTests {

    private func extracts(_ sources: [any Source]) async throws -> [LibraryExtract] {
        var all: [LibraryExtract] = []
        for source in sources { all.append(try await source.library()) }
        return all
    }

    @Test("Three core sources, three kinds — the segment shows all three")
    func segment() async throws {
        let extracts = try await extracts(MockShelf.base())
        let kinds = Set(extracts.flatMap(\.title).map(\.kind))
        #expect(kinds == [.manga, .book, .audiobook])
        #expect(Kind.allCases.filter(kinds.contains) == [.manga, .book, .audiobook])
    }

    @Test("With the podcast server there are all four kinds; the episodes hang on their series")
    func podcasts() async throws {
        let extracts = try await extracts(MockShelf.all())
        let kinds = Set(extracts.flatMap(\.title).map(\.kind))
        #expect(kinds == Set(Kind.allCases))
        #expect(Kind.allCases.filter(kinds.contains) == [.manga, .book, .audiobook, .podcast])
        let episodes = extracts.flatMap(\.title).filter { $0.kind == .podcast }
        #expect(episodes.count == 4)
        #expect(episodes.allSatisfy { $0.series?.name == "Moonlit Tales Podcast" && $0.kind.isAudible })
        #expect(episodes.map { $0.series?.volume } == [1, 2, 3, 4])
        #expect(episodes.allSatisfy { $0.identifier.id.hasPrefix("li_p1:") })
        let series = try #require(extracts.flatMap(\.seriesList).first { $0.kind == .podcast })
        #expect(series.volumeCount == 4)
    }

    @Test("Without Grimmory \"Books\" is missing from the segment — it is not empty")
    func withoutGrimmory() async throws {
        let extracts = try await extracts([MockShelf.komga(), MockShelf.audiobookshelf()])
        let kinds = Set(extracts.flatMap(\.title).map(\.kind))
        #expect(kinds == [.manga, .audiobook])
        #expect(Kind.allCases.filter(kinds.contains) == [.manga, .audiobook])
    }

    @Test("Counters per kind come from the titles, not from the provider")
    func counter() async throws {
        let title = try await extracts(MockShelf.base()).flatMap(\.title)
        let counter = Dictionary(grouping: title, by: \.kind).mapValues(\.count)
        #expect(counter == [.manga: 3, .book: 3, .audiobook: 3])
        #expect(title.count == 9)
    }

    @Test("\"Continue reading\" across three servers: started titles, newest first")
    func continueReading() async throws {
        let extracts = try await extracts(MockShelf.base())
        let title = Dictionary(uniqueKeysWithValues: extracts.flatMap(\.title).map { ($0.identifier, $0) })
        let proceed =
            extracts.flatMap { $0.readingStates.map { ($0.key, $0.value) } }
            .filter { $0.1.started }
            .sorted { $0.1.timestamp > $1.1.timestamp }
            .map { title[$0.0]!.name }
        #expect(
            proceed == [
                "The Memoirs of Sherlock Holmes", "Pepper&Carrot 37", "The Time Machine",
                "The Adventures of Sherlock Holmes",
            ])
    }

    @Test("The completed volume counts as read and does not appear in \"Continue reading\"")
    func read() async throws {
        let komga = try await MockShelf.komga().library()
        let read = komga.readingStates.values.filter(\.completed).count
        #expect(read == 1)
        #expect(komga.seriesList.first?.volumeCount == 3)
        let started = komga.readingStates.filter { $0.value.started }.map { $0.key.id }
        #expect(started == ["0K7Q3XJ1-47"])
    }

    @Test("The keep button depends on the capability, not on the provider")
    func keep() {
        let withButton = MockShelf.base().filter { $0.capabilities.contains(.keep) }.map(
            \.identifier.provider)
        #expect(withButton == [.komga, .audiobookshelf])
        let withSeries = MockShelf.base().filter { $0.capabilities.contains(.seriesList) }.map(
            \.identifier.provider)
        #expect(withSeries == [.komga, .grimmory])
        let withSavedList = MockShelf.base().filter { $0.capabilities.contains(.savedList) }.map(
            \.identifier.provider)
        #expect(withSavedList == [.grimmory])
    }

    @Test("Content arrives per kind on its own path — stream, file, audio")
    func content() async throws {
        let komga = MockShelf.komga()
        let volume = try await komga.library().title[1]
        let strom = komga.content(volume)
        #expect(strom.pageCount == 205)
        if case .pageStream(_, let page, _) = strom {
            #expect(page(63).absoluteString == "https://comics.example/api/v1/books/0K7Q3XJ1-47/pages/63")
        }
        let grimmory = MockShelf.grimmoryReadOnly()
        let book = try await grimmory.library().title[0]
        guard case .file(let address, let size, let area) = grimmory.content(book) else {
            Issue.record("Ein Buch ist eine Datei")
            return
        }
        #expect(address.host() == "buecher.example")
        #expect(size == 800_000)
        #expect(area)
        let abs = MockShelf.audiobookshelf()
        let audiobook = try await abs.library().title[0]
        guard case .audioStream(let fetch) = abs.content(audiobook) else {
            Issue.record("Ein Hörbuch ist ein Ton-Strom")
            return
        }
        let audio = try await fetch()
        #expect(audio.chapter.count == 3)
        #expect(audio.tracks.count == 634 && audio.duration == 38_000)
    }

    @Test("Written is read: a new state comes back on the next fetch")
    func writeAndRead() async throws {
        let komga = MockShelf.komga()
        let volume = try await komga.library().title[1]
        let previously = try await komga.progress(volume.identifier)
        #expect(previously?.fraction == 63.0 / 205.0)
        let new = ReadingState(
            position: .page(112, from: 205), timestamp: MockShelf.state, device: "iPhone")
        try await komga.write(new, for: volume.identifier)
        #expect(try await komga.progress(volume.identifier) == new)
        #expect(try await komga.library().readingStates[volume.identifier] == new)
        #expect(komga.written.count == 1)
        #expect(komga.written.first?.0 == volume.identifier)
    }

    @Test("An unknown title is \"not found\", not a network question")
    func notFound() async {
        let komga = MockShelf.komga()
        let fremd = TitleID(source: komga.identifier, id: "gibt-es-nicht")
        await #expect(throws: SourceError.notFound(fremd)) {
            try await komga.title(fremd)
        }
    }

    @Test("Unreachable means: every fetch fails with the same answer")
    func unreachable() async throws {
        let komga = MockShelf.komga()
        let volume = try await komga.library().title[0]
        komga.set(network: .unreachable)
        await #expect(throws: SourceError.unreachable(komga.identifier)) { try await komga.library() }
        await #expect(throws: SourceError.unreachable(komga.identifier)) {
            try await komga.title(volume.identifier)
        }
        await #expect(throws: SourceError.unreachable(komga.identifier)) {
            try await komga.progress(volume.identifier)
        }
        komga.set(network: .slow(mbit: 0.3))
        #expect(try await komga.library().title.count == 3)
        #expect(komga.fetches == 2)
    }
}
