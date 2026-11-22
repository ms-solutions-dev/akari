import CryptoKit
import Foundation
import SourcesKit

/// A kept title: where it lies, how big it is, whether it is entirely there.
///
/// Lies under `Application Support/behalten/<digest>/` — not in the cache, because
/// the system may evict that and the app does so itself; kept items stay until the
/// user releases them. Excluded from the iCloud backup: 74 MB per volume do not
/// belong in the phone's backup.
public struct KeptItem: Sendable, Codable, Hashable, Identifiable {

    public enum Status: Sendable, Codable, Hashable {
        /// Being fetched — progress 0 … 1, bytes so far.
        case ongoing(fraction: Double, bytes: Int64)
        case done
        /// Cancelled or failed — the rest stays, the next attempt resumes where the server
        /// supports `Range`.
        case disrupted(String)

        enum CodingKeys: String, CodingKey, CaseIterable {
            case ongoing = "laufend"
            case done = "fertig"
            case disrupted = "gestoert"
        }
        enum OngoingCodingKeys: String, CodingKey, CaseIterable {
            case fraction = "anteil"
            case bytes
        }
        enum DisruptedCodingKeys: String, CodingKey, CaseIterable {
            case _0
        }
    }

    public let identifier: TitleID
    public let name: String
    public let kind: Kind
    public let since: Date
    /// Bytes on the device — growing while fetching, the sum when done.
    public let size: Int64
    public let state: Status
    /// The files in reading order — one for EPUB/PDF, one per page for the page stream,
    /// one per track for the audiobook; relative to the title's folder.
    public let files: [String]
    /// The data package of the title — everything the server knows about it, including
    /// the blurb, as in the package when sending. That way a kept title also appears on
    /// the shelf when no catalog supplies it: offline, source too large, account signed
    /// out. `nil` for entries from before, until
    /// ``StockService/supplement(title:source:transport:)`` fills it in.
    public let title: Title?
    /// The cover as a file in the title's folder (`cover.jpg`), if it was fetched.
    public let coverFile: String?

    public var id: TitleID { identifier }
    public var done: Bool { if case .done = state { true } else { false } }

    public init(
        identifier: TitleID, name: String, kind: Kind, since: Date, size: Int64, state: Status,
        files: [String], title: Title? = nil, coverFile: String? = nil
    ) {
        self.title = title
        self.coverFile = coverFile
        self.identifier = identifier
        self.name = name
        self.kind = kind
        self.since = since
        self.size = size
        self.state = state
        self.files = files
    }

    public func with(state: Status, size: Int64? = nil, files: [String]? = nil) -> KeptItem {
        KeptItem(
            identifier: identifier, name: name, kind: kind, since: since, size: size ?? self.size,
            state: state,
            files: files ?? self.files, title: title, coverFile: coverFile)
    }

    /// With data package.
    public func with(title: Title, coverFile: String?) -> KeptItem {
        KeptItem(
            identifier: identifier, name: title.name, kind: kind, since: since, size: size, state: state,
            files: files, title: title, coverFile: coverFile ?? self.coverFile)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier = "kennung"
        case name
        case kind = "art"
        case since = "seit"
        case size = "groesse"
        case state = "stand"
        case files = "dateien"
        case title = "titel"
        case coverFile = "coverDatei"
    }
}

/// The folder of kept items and its index (`index.json`).
public struct KeepStore: Sendable {

    public let folder: URL

    /// - Parameter folder: by default `Application Support/behalten`; tests pass their
    ///   own so nothing is left behind.
    public init(folder: URL? = nil) {
        self.folder =
            folder
            ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "behalten", directoryHint: .isDirectory)
    }

    private var index: URL { folder.appending(path: "index.json") }

    /// Forgiving: an unreadable entry goes missing alone — before, it made all downloads
    /// invisible although the files were there.
    public func restoreFromDisk() -> [KeptItem] {
        guard let data = try? Data(contentsOf: index) else { return [] }
        return (try? JSONDecoder().decode(Lenient<KeptItem>.self, from: data))?.wrappedValue ?? []
    }

    public func write(_ list: [KeptItem]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: index, options: .atomic)
        // No backup: kept items can be had from the server again at any time.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try? url.setResourceValues(values)
    }

    /// The folder of a title — a digest, so no server name appears in the path.
    public func folder(for identifier: TitleID) -> URL {
        let digest = SHA256.hash(data: Data(identifier.description.utf8)).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        return folder.appending(path: digest, directoryHint: .isDirectory)
    }

    public func remove(_ identifier: TitleID) {
        try? FileManager.default.removeItem(at: folder(for: identifier))
    }

    /// What lies on disk, measured again — the directory count can lie after a crash in
    /// the middle of fetching.
    public func size(_ identifier: TitleID) -> Int64 {
        Cache.size(in: folder(for: identifier))
    }
}
