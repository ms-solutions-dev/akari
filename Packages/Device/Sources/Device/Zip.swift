import Compression
import Foundation

/// Read and write a ZIP archive — enough for EPUB, CBZ and the package of its own:
/// entries stored (method 0) or with Deflate (method 8), no encryption,
/// no ZIP64. Writing is always stored: EPUB and CBZ are already compressed,
/// compressing again would gain nothing. Deflate is inflated by the system (`Compression`).
///
/// No ZIPFoundation: Readium brings it only for iOS, and this source also runs
/// on the Mac in the tests.
///
/// Two ways to the same bytes: ``init(data:)`` has the whole archive in memory;
/// ``Remote`` only knows the tail and fetches each entry as a range of its own —
/// for an EPUB on a WebDAV server of which only cover and OPF are needed.
public struct Zip: Sendable {

    /// An entry of the central directory. `Codable` so that a source can cache the position
    /// of a cover and later fetch it with a single range request, without reading the directory again.
    public struct Item: Sendable, Hashable, Codable {
        public let name: String
        public let size: Int
        let method: UInt16
        let packed: Int
        let offset: Int
        /// Name plus extra length, as the central directory states it — the estimate
        /// of how long the local header before the data is.
        let headLength: Int

        enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case size = "groesse"
            case method = "methode"
            case packed = "gepackt"
            case offset = "versatz"
            case headLength = "kopfLaenge"
        }
    }

    public enum Failure: Error, Equatable {
        case noArchive
        case entryMissing(String)
        case methodUnknown(UInt16)
        case corrupted
        /// The tail does not reach the central directory — this many bytes from the
        /// end are needed by the reader.
        case tailTooShort(needed: Int)
        /// The fetched range ends before the entry's data — this many bytes from the
        /// entry's offset are needed by the reader.
        case rangeTooShort(needed: Int)
    }

    private let data: Data
    public let entries: [Item]

    public init(data: Data) throws {
        self.data = data
        self.entries = try Zip.directory(data, startTime: 0)
    }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func entry(_ name: String) -> Item? {
        entries.first { $0.name == name }
    }

    /// The content of an entry, unpacked.
    public func content(_ name: String) throws -> Data {
        guard let e = entry(name) else { throw Failure.entryMissing(name) }
        return try content(e)
    }

    public func content(_ e: Item) throws -> Data {
        try Zip.unpack(e, from: data, startTime: 0)
    }

    // MARK: - Reading

    /// Reads the central directory from `d`, whose first byte lies at `startTime` in the
    /// archive — `0` for the whole archive, otherwise the start of the tail.
    private static func directory(_ d: Data, startTime: Int) throws -> [Item] {
        // End of Central Directory: signature 0x06054b50, searched from the back (comment up to 64 KB).
        guard d.count >= 22 else { throw Failure.noArchive }
        var end = -1
        var i = d.count - 22
        let limit = max(0, d.count - 22 - 65535)
        while i >= limit {
            if d[d.startIndex + i] == 0x50, d[d.startIndex + i + 1] == 0x4B, d[d.startIndex + i + 2] == 0x05,
                d[d.startIndex + i + 3] == 0x06
            {
                end = i
                break
            }
            i -= 1
        }
        guard end >= 0 else { throw Failure.noArchive }
        let count = Int(read16(d, end + 10))
        let size = Int(read32(d, end + 12))
        let offsetInArchive = Int(read32(d, end + 16))
        guard offsetInArchive >= startTime else {
            throw Failure.tailTooShort(needed: startTime + d.count - offsetInArchive)
        }
        let offset = offsetInArchive - startTime
        guard offset + size <= d.count else { throw Failure.corrupted }
        var entries: [Item] = []
        var p = offset
        for _ in 0..<count {
            guard p + 46 <= d.count, read32(d, p) == 0x0201_4B50 else { throw Failure.corrupted }
            let method = read16(d, p + 10)
            let packed = Int(read32(d, p + 20))
            let unpacked = Int(read32(d, p + 24))
            let nameLength = Int(read16(d, p + 28))
            let extraLength = Int(read16(d, p + 30))
            let commentLength = Int(read16(d, p + 32))
            let local = Int(read32(d, p + 42))
            guard p + 46 + nameLength <= d.count else { throw Failure.corrupted }
            let name = String(
                decoding: d.subdata(in: (d.startIndex + p + 46)..<(d.startIndex + p + 46 + nameLength)),
                as: UTF8.self)
            entries.append(
                Item(
                    name: name, size: unpacked, method: method, packed: packed, offset: local,
                    headLength: nameLength + extraLength))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Unpacks an entry from `d`, whose first byte lies at `startTime` in the archive.
    /// The local header repeats name and extra length, and the extra length
    /// may differ from the central directory — hence it is read, not estimated.
    private static func unpack(_ e: Item, from d: Data, startTime: Int) throws -> Data {
        let header = e.offset - startTime
        guard header >= 0, header + 30 <= d.count, read32(d, header) == 0x0403_4B50 else {
            throw Failure.corrupted
        }
        let nameLength = Int(read16(d, header + 26))
        let extraLength = Int(read16(d, header + 28))
        let data = header + 30 + nameLength + extraLength
        guard data + e.packed <= d.count else {
            throw Failure.rangeTooShort(needed: 30 + nameLength + extraLength + e.packed)
        }
        let raw = d.subdata(in: (d.startIndex + data)..<(d.startIndex + data + e.packed))
        switch e.method {
        case 0: return raw
        case 8: return try Zip.unpack(raw, size: e.size)
        default: throw Failure.methodUnknown(e.method)
        }
    }

    private static func unpack(_ raw: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var target = Data(count: size)
        let read = target.withUnsafeMutableBytes { targetBuffer -> Int in
            raw.withUnsafeBytes { rawBuffer -> Int in
                compression_decode_buffer(
                    targetBuffer.bindMemory(to: UInt8.self).baseAddress!, size,
                    rawBuffer.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard read == size else { throw Failure.corrupted }
        return target
    }

    private static func read16(_ d: Data, _ p: Int) -> UInt16 {
        let b = d.startIndex + p
        return UInt16(d[b]) | UInt16(d[b + 1]) << 8
    }

    private static func read32(_ d: Data, _ p: Int) -> UInt32 {
        let b = d.startIndex + p
        return UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
    }

    // MARK: - Writing

    /// An archive from entries, stored, with CRC-32 — what every unzipper reads.
    public static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var central = Data()
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let checksum = crc32(data)
            let offset = UInt32(archive.count)
            archive.append(integer(UInt32(0x0403_4B50)))
            archive.append(integer(UInt16(20)))
            archive.append(integer(UInt16(0x0800)))  // UTF-8 names
            archive.append(integer(UInt16(0)))
            archive.append(integer(UInt16(0)))
            archive.append(integer(UInt16(0x21)))
            archive.append(integer(checksum))
            archive.append(integer(UInt32(data.count)))
            archive.append(integer(UInt32(data.count)))
            archive.append(integer(UInt16(nameBytes.count)))
            archive.append(integer(UInt16(0)))
            archive.append(nameBytes)
            archive.append(data)

            central.append(integer(UInt32(0x0201_4B50)))
            central.append(integer(UInt16(20)))
            central.append(integer(UInt16(20)))
            central.append(integer(UInt16(0x0800)))
            central.append(integer(UInt16(0)))
            central.append(integer(UInt16(0)))
            central.append(integer(UInt16(0x21)))
            central.append(integer(checksum))
            central.append(integer(UInt32(data.count)))
            central.append(integer(UInt32(data.count)))
            central.append(integer(UInt16(nameBytes.count)))
            central.append(integer(UInt16(0)))
            central.append(integer(UInt16(0)))
            central.append(integer(UInt16(0)))
            central.append(integer(UInt16(0)))
            central.append(integer(UInt32(0)))
            central.append(integer(offset))
            central.append(nameBytes)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(integer(UInt32(0x0605_4B50)))
        archive.append(integer(UInt16(0)))
        archive.append(integer(UInt16(0)))
        archive.append(integer(UInt16(entries.count)))
        archive.append(integer(UInt16(entries.count)))
        archive.append(integer(UInt32(central.count)))
        archive.append(integer(centralOffset))
        archive.append(integer(UInt16(0)))
        return archive
    }

    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension Zip {

    /// An archive that is not stored here: the directory comes from the tail, each
    /// entry from a range of its own — the source fetches both via `Range`, the
    /// reader only computes. For a 2 MB EPUB on a WebDAV server that means
    /// 64 KB for the directory, a few KB for `container.xml` and OPF, the cover —
    /// instead of the whole file through a tunnel at 0.3 Mbit/s.
    ///
    /// Two errors are requests, not refusals: ``Failure/tailTooShort(needed:)``
    /// (the directory starts before the tail — fetch a bigger tail) and
    /// ``Failure/rangeTooShort(needed:)`` (the local header was longer than estimated —
    /// fetch the range from the offset again at this length).
    public struct Remote: Sendable, Hashable, Codable {
        /// How many bytes from the end usually suffice — a directory with a few
        /// hundred entries fits in it, comment included.
        public static let tail = 65_536
        /// What an entry's range takes beyond the estimated header: the local header
        /// carries a few bytes more than the directory with timestamp and Unix extra fields.
        static let reserve = 256

        /// The length of the whole file.
        public let size: Int
        public let entries: [Item]

        /// - Parameters:
        ///   - tail: the last bytes of the file
        ///   - size: the length of the whole file — from `Content-Range` or `getcontentlength`
        public init(tail: Data, size: Int) throws {
            guard tail.count <= size else { throw Failure.corrupted }
            self.size = size
            self.entries = try Zip.directory(tail, startTime: size - tail.count)
        }

        public func entry(_ name: String) -> Item? {
            entries.first { $0.name == name }
        }

        /// The range of the file that contains the entry including the local header — at
        /// most to the end of the file.
        public func area(_ e: Item) -> Range<Int> {
            Remote.area(e, size: size)
        }

        /// The same without the directory — for a cached entry.
        public static func area(_ e: Item, size: Int) -> Range<Int> {
            let end = min(size, e.offset + 30 + e.headLength + e.packed + Remote.reserve)
            return e.offset..<max(e.offset, end)
        }

        /// The content of an entry from the bytes of its ``area(_:)`` — they may be
        /// longer (the server rounds), not shorter.
        public static func content(_ e: Item, from data: Data) throws -> Data {
            try Zip.unpack(e, from: data, startTime: e.offset)
        }

        public func content(_ e: Item, from data: Data) throws -> Data {
            try Remote.content(e, from: data)
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case size = "groesse"
            case entries = "eintraege"
        }
    }
}
