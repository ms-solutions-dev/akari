import Foundation
import Testing

@testable import ReadingProgress
@testable import SourcesKit

/// Reading sessions are stored (and synced) as JSON. The expected strings were produced by the code as
/// it was before the English rename.
@Suite struct PersistedFormatTests {
    let stamp = Date(timeIntervalSinceReferenceDate: 7_000_000)

    func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func session() throws {
        let session = ReadingSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            identifier: TitleID(source: SourceID(provider: .komga, server: "comics.example"), id: "b1"),
            kind: .manga, startTime: stamp, end: stamp.addingTimeInterval(600), readingTime: 600, pages: 12,
            fraction: 0.5, completed: false, name: "Band 1")
        #expect(try json(session) == Golden.session)
        #expect(try JSONDecoder().decode(ReadingSession.self, from: Data(Golden.session.utf8)) == session)
    }
}

private enum Golden {
    static let session =
        #"{"abgeschlossen":false,"anteil":0.5,"art":"manga","beginn":7000000,"ende":7000600,"id":"00000000-0000-0000-0000-000000000001","kennung":{"id":"b1","quelle":{"anbieter":"komga","server":"comics.example"}},"lesezeit":600,"name":"Band 1","seiten":12}"#
}
