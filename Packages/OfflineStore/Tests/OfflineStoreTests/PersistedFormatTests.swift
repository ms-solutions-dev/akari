import Foundation
import Testing

@testable import OfflineStore

/// The offline index (`behalten/index.json`) is read by every future version. The expected strings were
/// produced by the code as it was before the English rename.
@Suite struct PersistedFormatTests {
    func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func keptState() throws {
        #expect(try json(KeptItem.Status.ongoing(fraction: 0.5, bytes: 1024)) == Golden.running)
        #expect(try json(KeptItem.Status.done) == Golden.done)
        #expect(try json(KeptItem.Status.disrupted("x")) == Golden.broken)
        #expect(
            try JSONDecoder().decode(KeptItem.Status.self, from: Data(Golden.running.utf8))
                == .ongoing(fraction: 0.5, bytes: 1024))
        #expect(try JSONDecoder().decode(KeptItem.Status.self, from: Data(Golden.done.utf8)) == .done)
        #expect(
            try JSONDecoder().decode(KeptItem.Status.self, from: Data(Golden.broken.utf8)) == .disrupted("x"))
    }
}

private enum Golden {
    static let running = #"{"laufend":{"anteil":0.5,"bytes":1024}}"#
    static let done = #"{"fertig":{}}"#
    static let broken = #"{"gestoert":{"_0":"x"}}"#
}
