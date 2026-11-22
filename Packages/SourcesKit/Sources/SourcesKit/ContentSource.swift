import Foundation

/// A chapter of an audiobook: name and position in seconds.
public struct Chapter: Sendable, Codable, Hashable {
    public let name: String
    public let startTime: TimeInterval
    public let end: TimeInterval

    public init(name: String, startTime: TimeInterval, end: TimeInterval) {
        self.name = name
        self.startTime = startTime
        self.end = end
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case startTime = "beginn"
        case end = "ende"
    }
}

/// The dimensions of a page in pixels — from the manifest, before loading.
///
/// The comic reader needs them for the double page: a landscape image (Krafruk has
/// 24 per volume) stands alone and is never paired with a second page, and
/// the decision is made from the manifest, not on display.
public struct PageSize: Sendable, Codable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Wider than tall — a double page as one image.
    public var landscape: Bool { width > height }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case width = "breite"
        case height = "hoehe"
    }
}

/// An audio track of an audiobook: a file on the server, its position in the whole.
/// Audiobookshelf delivers up to a hundred of them per audiobook (one per MP3 file);
/// the player queues them and computes the time in the book from `start + time in the track`.
///
/// `size` and `fileExtension` are needed by keeping: the size for "12 tracks ·
/// 412 MB" before fetching and for progress in bytes, the extension for the
/// file name on the device — AVPlayer recognises a file by its name, and the
/// address at Audiobookshelf (`/file/<ino>`) carries none. Both may be missing;
/// older records without the fields stay readable.
public struct AudioTrack: Sendable, Hashable, Codable {
    public let address: URL
    public let startTime: TimeInterval
    public let duration: TimeInterval
    /// Bytes of the file on the server, if it names them.
    public let size: Int64?
    /// File extension without a dot (`mp3`, `m4b`), if known.
    public let fileExtension: String?

    public init(
        address: URL, startTime: TimeInterval, duration: TimeInterval, size: Int64? = nil,
        fileExtension: String? = nil
    ) {
        self.address = address
        self.startTime = startTime
        self.duration = duration
        self.size = size
        self.fileExtension = fileExtension
    }

    public var end: TimeInterval { startTime + duration }

    /// The same track at a different address — the file on the device instead of the
    /// one on the server; position and duration stay.
    public func with(address new: URL) -> AudioTrack {
        AudioTrack(
            address: new, startTime: startTime, duration: duration, size: size, fileExtension: fileExtension)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case address = "adresse"
        case startTime = "beginn"
        case duration = "dauer"
        case size = "groesse"
        case fileExtension = "endung"
    }
}

/// Everything the player needs for playback — tracks, chapters, total duration.
public struct AudioManifest: Sendable, Hashable, Codable {
    public let tracks: [AudioTrack]
    public let chapter: [Chapter]
    public let duration: TimeInterval

    public init(tracks: [AudioTrack], chapter: [Chapter], duration: TimeInterval? = nil) {
        self.tracks = tracks
        self.chapter = chapter
        self.duration = duration ?? tracks.last?.end ?? 0
    }

    /// The sum of all tracks in bytes — `nil` as soon as one track does not know
    /// its size: half a sum would be a wrong number on the button.
    public var size: Int64? {
        var sum: Int64 = 0
        for track in tracks {
            guard let g = track.size else { return nil }
            sum += g
        }
        return tracks.isEmpty ? nil : sum
    }

    /// All tracks are files on the device — the player then needs
    /// no bridge.
    public var local: Bool {
        !tracks.isEmpty && tracks.allSatisfy(\.address.isFileURL)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case tracks = "spuren"
        case chapter = "kapitel"
        case duration = "dauer"
    }
}

/// How a title gets to the reader — three ways, none of them "load".
///
/// - ``pageStream(count:page:measures:)``: page by page from the server, each with its own
///   address. The comic reader fetches what it shows, and two ahead. `measures` fetches the
///   manifest with the page sizes, where the server has one (Komga); `nil` means: all
///   pages count as portrait until they are loaded.
/// - ``file(_:size:rangeCapable:)``: one file, fetched on opening (0.8 MB
///   median for an EPUB). `rangeCapable` says whether the server understands `Range` —
///   then an interrupted fetch may resume instead of starting over.
/// - ``audioStream(_:)``: fetches the ``AudioManifest`` — tracks and chapters are known only to
///   the detail, hence a function and not a value.
///
/// Not `Equatable`: the page stream carries a function, and that cannot be compared.
/// Whoever wants to compare two content sources compares the title identifier.
public enum ContentSource: Sendable {
    case pageStream(
        count: Int, page: @Sendable (Int) -> URL, measures: (@Sendable () async throws -> [PageSize])? = nil)
    case file(URL, size: Int64?, rangeCapable: Bool)
    case audioStream(@Sendable () async throws -> AudioManifest)

    /// How many pages the stream has — `nil` for everything that knows no pages.
    public var pageCount: Int? {
        if case .pageStream(let count, _, _) = self { return count }
        return nil
    }
}
