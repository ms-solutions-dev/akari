import Foundation

/// The iCloud key-value store, as it carried bookmarks, theme and reading time:
/// now only for the **transition**: read once, write into the zone, remove the
/// key. In operation `NSUbiquitousKeyValueStore.default`, in tests a box in
/// memory.
public protocol KeyStorage: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyStorage {}

/// A key in the old store that a package picks up on first launch.
/// ``data()``/``text()`` read, ``remove()`` cleans up; afterwards the key exists
/// nowhere any more, and the other device finds nothing at its own transition
/// (it has its state locally anyway, and the zone brings the rest).
public struct LegacyData {
    public let storage: any KeyStorage
    public let lookupKey: String

    public init(_ storage: any KeyStorage, lookupKey: String) {
        self.storage = storage
        self.lookupKey = lookupKey
    }

    public func data() -> Data? { storage.data(forKey: lookupKey) }
    public func text() -> String? { storage.string(forKey: lookupKey) }

    public func remove() {
        storage.removeObject(forKey: lookupKey)
        storage.synchronize()
    }
}

/// A box in memory, for tests and the preview.
public final class StorageMock: KeyStorage, @unchecked Sendable {
    public var values: [String: Any] = [:]

    public init(_ values: [String: Any] = [:]) { self.values = values }

    public func data(forKey key: String) -> Data? { values[key] as? Data }
    public func string(forKey key: String) -> String? { values[key] as? String }
    public func removeObject(forKey key: String) { values[key] = nil }
    public func synchronize() -> Bool { true }
}

extension ProfileZone {

    /// The whole mirror as readable JSON: "Export" in the "iCloud & Devices" sheet.
    /// What lies in the zone belongs to the reader, and they should be able to take
    /// it with them.
    public func export() -> Data? {
        struct Output: Encodable {
            let zone: String?
            let state: Date
            let records: [CloudRecord]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case zone
                case state = "stand"
                case records = "datensaetze"
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let all = types().sorted().flatMap { allRecords(ofType: $0) }
        let withoutSeal = all.map { record in
            var s = record
            s.seal = nil
            return s
        }
        return try? encoder.encode(Output(zone: zone?.name, state: Date(), records: withoutSeal))
    }

    /// How many records per type lie in the mirror: the row "312 sessions, 14 bookmarks".
    public func count(_ type: String) -> Int { allRecords(ofType: type).count }
}
