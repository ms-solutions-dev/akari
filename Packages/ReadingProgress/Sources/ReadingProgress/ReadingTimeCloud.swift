import Foundation
import SourcesKit

/// The version of the log that used to go into the iCloud key-value store; now only
/// read for the **transition** (``unpack(_:)``): the carrier is the CloudKit zone with
/// one record per session. Kept small because the key-value store allowed **1 MB for
/// everything together** (and 1 MB per key, 1,024 keys): each profile's watch list and
/// theme live there too, and a family iPad has three or four profiles on one Apple ID.
///
/// **The arithmetic:** a session as ordinary JSON (ISO dates, full field names, the
/// identifier with provider and server) weighs about 290 bytes; a year at five sessions
/// a day would be 1,825 sessions, about 530 KB. One profile alone would fill half the
/// store, two the whole. Hence three measures:
///
/// 1. **Only the last twelve months** (``window``): the statistics show week, month,
///    year, and what is older needs no other device. Locally, everything stays.
/// 2. **Compact encoding** (``Item``): one row of twelve values per session without
///    field names, times as whole seconds, the fraction to four places, about 140 bytes
///    instead of 290.
/// 3. **Compressed** (zlib): sessions of the same title repeat provider, server,
///    identifier and names; compressed that leaves about 40 bytes per session. A year at
///    five sessions a day is about 75 KB.
///
/// **The cap** (``cap``) is 200 KB per profile: four profiles are about 800 KB, and the
/// rest is left for watch list and theme. At 40 bytes per session that is about 5,000
/// sessions, just under fourteen a day for a whole year, before the cap bites ahead of
/// the window. If it does, the oldest drop until it fits.
public enum ReadingTimeCloud {

    /// Twelve months. Calendar months do not matter here; 365 days are enough.
    public static let window: TimeInterval = 365 * 86_400
    /// 200 KB compressed; see the arithmetic above.
    public static let cap = 200 * 1024

    /// A session as a row without field names: identifier, provider, server, title,
    /// kind, start and end in whole seconds, reading time in seconds, pages, fraction to
    /// four places, completed, name. The order is the agreement: a thirteenth value
    /// would be appended at the end, and older versions read the twelve.
    struct Item: Codable {
        let session: ReadingSession

        init(_ session: ReadingSession) { self.session = session }

        func encode(to encoder: any Encoder) throws {
            var row = encoder.unkeyedContainer()
            let s = session
            try row.encode(s.id.uuidString)
            try row.encode(s.identifier.source.provider.rawValue)
            try row.encode(s.identifier.source.server)
            try row.encode(s.identifier.id)
            try row.encode(s.kind.rawValue)
            try row.encode(Int(s.startTime.timeIntervalSince1970.rounded()))
            try row.encode(Int(s.end.timeIntervalSince1970.rounded()))
            try row.encode(Int(s.readingTime.rounded()))
            try row.encode(s.pages)
            try row.encode((s.fraction * 10_000).rounded() / 10_000)
            try row.encode(s.completed)
            try row.encode(s.name)
        }

        init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            let id = try row.decode(String.self)
            let provider = try row.decode(String.self)
            let server = try row.decode(String.self)
            let title = try row.decode(String.self)
            let kind = try row.decode(String.self)
            let startTime = try row.decode(Int.self)
            let end = try row.decode(Int.self)
            let readingTime = try row.decode(Int.self)
            let pages = try row.decode(Int.self)
            let fraction = try row.decode(Double.self)
            let completed = try row.decode(Bool.self)
            let name = try row.decodeIfPresent(String.self)
            guard let uuid = UUID(uuidString: id), let provider = Provider(rawValue: provider),
                let kind = Kind(rawValue: kind)
            else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath, debugDescription: "Unknown row"))
            }
            session = ReadingSession(
                id: uuid,
                identifier: TitleID(source: SourceID(provider: provider, server: server), id: title),
                kind: kind, startTime: Date(timeIntervalSince1970: TimeInterval(startTime)),
                end: Date(timeIntervalSince1970: TimeInterval(end)), readingTime: TimeInterval(readingTime),
                pages: pages, fraction: fraction, completed: completed, name: name)
        }
    }

    /// The cloud version: the sessions within the window, sorted by end, compact and
    /// compressed, and under the cap: if it does not fit, the oldest ten percent drop
    /// each round. `nil` only if the compression itself fails.
    public static func pack(
        _ sessions: [ReadingSession], now: Date = Date(), cap: Int = ReadingTimeCloud.cap
    ) -> Data? {
        let cutoff = now.addingTimeInterval(-window)
        var included = sessions.filter { $0.end >= cutoff }.sorted { $0.end < $1.end }
        while true {
            guard let raw = try? JSONEncoder().encode(included.map(Item.init)),
                let packed = try? (raw as NSData).compressed(using: .zlib) as Data
            else { return nil }
            if packed.count <= cap || included.isEmpty { return packed }
            included.removeFirst(max(included.count / 10, 1))
        }
    }

    /// The sessions from a cloud version, or `nil` if the data is not one.
    public static func unpack(_ data: Data) -> [ReadingSession]? {
        guard let raw = try? (data as NSData).decompressed(using: .zlib) as Data,
            let entries = try? JSONDecoder().decode([Item].self, from: raw)
        else { return nil }
        return entries.map(\.session)
    }
}
