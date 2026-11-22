import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// The child profile: the shelf with maximum age.
@Suite("Shelf with maximum age")
struct RegalKinderTests {

    private func extracts() async throws -> [LibraryExtract] {
        var extracts: [LibraryExtract] = []
        for q in MockShelf.base() { extracts.append(try await q.library()) }
        return extracts
    }

    @Test("Without limit everything; from 12 the manga series (12) stays, from 6 it drops with its volumes")
    func limit() async throws {
        let alles = Shelf(extracts: try await extracts(), bookSeriesList: [], now: MockShelf.state)
        let ab12 = Shelf(
            extracts: try await extracts(), bookSeriesList: [], maxAge: 12, now: MockShelf.state)
        let ab6 = Shelf(
            extracts: try await extracts(), bookSeriesList: [], maxAge: 6, now: MockShelf.state)
        #expect(alles.maxAge == nil)
        #expect(ab12.counter(.manga) == alles.counter(.manga))
        #expect(ab6.counter(.manga) == Shelf.Counter(seriesList: 0, title: 0))
        #expect(ab6.allSeries.allSatisfy { $0.kind != .manga })
        // What carries no rating stays — books and audiobooks of the mocks.
        #expect(ab6.counter(.book) == alles.counter(.book))
        #expect(ab6.counter(.audiobook) == alles.counter(.audiobook))
        #expect(ab6.kinds == [.book, .audiobook])
        // Continue reading and search no longer know the blocked volumes.
        #expect(ab6.continueReading.allSatisfy { $0.title.kind != .manga })
        #expect(ab6.search("Pepper&Carrot").clusters.isEmpty)
        #expect(!ab12.search("Pepper&Carrot").clusters.isEmpty)
    }

    @Test("A volume above the limit drops alone; a volume without rating in a blocked series drops with it")
    func singles() {
        let source = SourceID(provider: .komga, server: "comics.example")
        let free = SeriesID(source: source, id: "frei")
        let locked = SeriesID(source: source, id: "gesperrt")
        func volume(_ id: String, _ series: SeriesID, age: Int?) -> Title {
            Title(
                identifier: TitleID(source: source, id: id), kind: .manga, name: id,
                series: SeriesReference(identifier: series, name: series.id, volume: 1), ageRating: age)
        }
        let extract = LibraryExtract(
            source: source,
            seriesList: [
                Series(identifier: free, kind: .manga, name: "frei", volumeCount: 2),
                Series(identifier: locked, kind: .manga, name: "gesperrt", volumeCount: 1, ageRating: 16),
            ],
            title: [
                volume("a", free, age: nil), volume("b", free, age: 16), volume("c", locked, age: nil),
            ],
            readingStates: [
                TitleID(source: source, id: "b"): ReadingState(
                    position: .page(1, from: 2), timestamp: Date())
            ],
            state: Date())
        let shelf = Shelf(extracts: [extract], maxAge: 12)
        #expect(shelf.allTitles.map(\.name) == ["a"])
        #expect(shelf.allSeries.map(\.name) == ["frei"])
        #expect(shelf.readingStates.isEmpty)
        // The copies keep the limit.
        #expect(shelf.with(keep: []).maxAge == 12)
        #expect(shelf.with(bookSeriesList: [.book]).allTitles.count == 1)
    }
}
