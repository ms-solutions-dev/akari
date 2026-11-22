import Foundation
import Testing

@testable import WidgetBridge

/// The widget reads these files from the App Group, written by an older or newer app version. The expected
/// strings were produced by the code as it was before the English rename.
@Suite struct PersistedFormatTests {
    let stamp = Date(timeIntervalSinceReferenceDate: 7_000_000)

    func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func continueReadingSnapshot() throws {
        let entry = ContinueReadingSnapshot.Item(
            id: "k1", name: "Titel", subline: "Band 2", kind: .book, fraction: 0.4, state: "S. 4",
            link: URL(string: "akari://oeffne/k1")!, cover: "k1.jpg")
        let snapshot = ContinueReadingSnapshot(
            profile: "Alex", multipleProfiles: true, entries: [entry], written: stamp)
        #expect(try json(snapshot) == Golden.snapshot)
        #expect(
            try JSONDecoder().decode(ContinueReadingSnapshot.self, from: Data(Golden.snapshot.utf8))
                == snapshot)
    }
}

private enum Golden {
    static let snapshot =
        #"{"eintraege":[{"anteil":0.4,"art":"buch","cover":"k1.jpg","id":"k1","link":"akari:\/\/oeffne\/k1","name":"Titel","stand":"S. 4","unterzeile":"Band 2"}],"geschrieben":7000000,"mehrereProfile":true,"profil":"Alex"}"#
}
