import Foundation
import Testing

@testable import SourcesKit

/// Values that end up on disk, in the Keychain or in iCloud keep their original (German) JSON.
/// The expected strings were produced by the code as it was before the English rename; a failing
/// test here means existing installs would no longer read their own data.
@Suite struct PersistedFormatTests {
    let stamp = Date(timeIntervalSinceReferenceDate: 7_000_000)

    func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func roundTrip<T: Codable & Equatable>(_ value: T, _ text: String) throws {
        #expect(try JSONDecoder().decode(T.self, from: Data(text.utf8)) == value)
    }

    @Test func readingStatePositions() throws {
        let page = ReadingState(
            position: .page(3, from: 10), timestamp: stamp, device: "iPhone", completed: false)
        let cfi = ReadingState(position: .position(cfi: "/6/4!/4/2", fraction: 0.5), timestamp: stamp)
        let second = ReadingState(position: .second(90, from: 3600), timestamp: stamp, completed: true)
        let share = ReadingState(position: .fraction(0.25), timestamp: stamp)
        #expect(try json(page) == Golden.page)
        #expect(try json(cfi) == Golden.cfi)
        #expect(try json(second) == Golden.second)
        #expect(try json(share) == Golden.share)
        try roundTrip(page, Golden.page)
        try roundTrip(cfi, Golden.cfi)
        try roundTrip(second, Golden.second)
        try roundTrip(share, Golden.share)
    }

    @Test func identifiers() throws {
        let source = SourceID(provider: .komga, server: "comics.example")
        let title = TitleID(source: source, id: "b1")
        #expect(try json(source) == Golden.source)
        #expect(try json(title) == Golden.title)
        try roundTrip(title, Golden.title)
    }

    @Test func scope() throws {
        #expect(try json(Scope.pages(12)) == Golden.scopePages)
        #expect(try json(Scope.duration(60)) == Golden.scopeDuration)
        #expect(try json(Scope.unknown) == Golden.scopeUnknown)
        try roundTrip(Scope.pages(12), Golden.scopePages)
        try roundTrip(Scope.duration(60), Golden.scopeDuration)
    }

    @Test func rating() throws {
        let rating = Rating(stars: 4.5, voices: 12, origin: "komga")
        #expect(try json(rating) == Golden.rating)
        try roundTrip(rating, Golden.rating)
    }
}

private enum Golden {
    static let page =
        #"{"abgeschlossen":false,"geraet":"iPhone","position":{"seite":{"_0":3,"von":10}},"zeitstempel":7000000}"#
    static let cfi =
        #"{"abgeschlossen":false,"position":{"position":{"anteil":0.5,"cfi":"\/6\/4!\/4\/2"}},"zeitstempel":7000000}"#
    static let second =
        #"{"abgeschlossen":true,"position":{"sekunde":{"_0":90,"von":3600}},"zeitstempel":7000000}"#
    static let share = #"{"abgeschlossen":false,"position":{"anteil":{"_0":0.25}},"zeitstempel":7000000}"#
    static let source = #"{"anbieter":"komga","server":"comics.example"}"#
    static let title = #"{"id":"b1","quelle":{"anbieter":"komga","server":"comics.example"}}"#
    static let scopePages = #"{"seiten":{"_0":12}}"#
    static let scopeDuration = #"{"dauer":{"_0":60}}"#
    static let scopeUnknown = #"{"unbekannt":{}}"#
    static let rating = #"{"herkunft":"komga","sterne":4.5,"stimmen":12}"#
}
