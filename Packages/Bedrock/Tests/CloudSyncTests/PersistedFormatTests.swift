import Foundation
import Testing

@testable import CloudSync

/// CloudKit record mirrors are stored as JSON next to the profile. The expected strings were produced
/// by the code as it was before the English rename.
@Suite struct PersistedFormatTests {
    let stamp = Date(timeIntervalSinceReferenceDate: 7_000_000)

    func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func fieldValues() throws {
        #expect(try json(FieldValue.text("a")) == Golden.text)
        #expect(try json(FieldValue.integer(3)) == Golden.int)
        #expect(try json(FieldValue.decimalNumber(1.5)) == Golden.double)
        #expect(try json(FieldValue.time(stamp)) == Golden.date)
        #expect(try json(FieldValue.truth(true)) == Golden.bool)
        #expect(try json(FieldValue.data(Data([1, 2]))) == Golden.data)
        #expect(try JSONDecoder().decode(FieldValue.self, from: Data(Golden.int.utf8)) == .integer(3))
        #expect(try JSONDecoder().decode(FieldValue.self, from: Data(Golden.bool.utf8)) == .truth(true))
    }

    @Test func record() throws {
        let record = CloudRecord(
            type: "Lesestand", name: "t1", fields: ["anteil": .decimalNumber(0.5), "name": .text("x")],
            changed: stamp, seal: nil, creator: "me", encrypted: ["name"], serverTime: stamp)
        #expect(try json(record) == Golden.record)
        #expect(try json(ZoneID(name: "profil-1", owner: "x")) == Golden.zone)
        #expect(try json(ZoneID(name: "profil-1")) == Golden.ownZone)
        #expect(try JSONDecoder().decode(CloudRecord.self, from: Data(Golden.record.utf8)) == record)
    }
}

private enum Golden {
    static let text = #"{"text":{"_0":"a"}}"#
    static let int = #"{"zahl":{"_0":3}}"#
    static let double = #"{"kommazahl":{"_0":1.5}}"#
    static let date = #"{"zeit":{"_0":7000000}}"#
    static let bool = #"{"wahrheit":{"_0":true}}"#
    static let data = #"{"daten":{"_0":"AQI="}}"#
    static let record =
        #"{"ersteller":"me","felder":{"anteil":{"kommazahl":{"_0":0.5}},"name":{"text":{"_0":"x"}}},"geaendert":7000000,"name":"t1","serverzeit":7000000,"typ":"Lesestand","verschluesselt":["name"]}"#
    static let zone = #"{"besitzer":"x","name":"profil-1"}"#
    static let ownZone = #"{"name":"profil-1"}"#
}
