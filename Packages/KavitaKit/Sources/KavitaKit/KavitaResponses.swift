import Foundation
import SourcesKit

/// The responses of Kavita 0.9.1, as far as the kit reads them — fields missing here
/// are ignored by the decoder. Names as in the JSON, so the recording in
/// `Fixtures` and the source speak the same language.
///
/// **Almost everything is optional:** Kavita sends numeric enumerations (`format`, `type`,
/// `ageRating`) and a field it does not know as `null` or not at all. A
/// chapter that lacks a field should still be on the shelf.
enum KavitaResponses {

    /// `POST /api/Account/login` and `GET /api/Account/refresh-account` (`UserDto`).
    /// `token` is a JWT, `apiKey` the key with which Kavita serves OPDS —
    /// the same as the auth key "opds".
    struct User: Decodable {
        let id: Int
        let username: String?
        let email: String?
        let roles: [String]?
        let token: String?
        let apiKey: String?
        let kavitaVersion: String?
    }

    /// `POST /api/Account/login`.
    struct SignInBody: Encodable {
        let username: String
        let password: String
    }

    /// `POST /api/Account/create-auth-key` (`RotateAuthKeyRequestDto`): `keyLength`
    /// between 8 and 32 per OpenAPI, `name` not empty.
    struct CreateAuthKey: Encodable {
        let keyLength: Int
        let name: String
    }

    /// The response to it (`AuthKeyDto`).
    struct EntryKey: Decodable {
        let id: Int
        let key: String?
        let name: String?
    }

    /// `GET /api/Library/libraries` (`LibraryDto`). `type`: 0 Manga, 1 Comic,
    /// 2 Book, 3 Image, 4 Light Novel, 5 Comic (ComicVine).
    struct Library: Decodable {
        let id: Int
        let name: String?
        let type: Int?
    }

    /// The body for `POST /api/Series/all-v2` (`SeriesFilterV2Dto`): without a condition,
    /// by sort name — `combination` 1 means "and", `sortField` 1 "SortName".
    struct SeriesFilter: Encodable {
        let id = 0
        let statements: [String] = []
        let combination = 1
        let sortOptions = Sorting()
        let limitTo = 0

        struct Sorting: Encodable {
            let sortField = 1
            let isAscending = true
        }
    }

    /// The `Pagination` header on `all-v2` — Kavita pages there, not in the body.
    struct Sheet: Decodable {
        let currentPage: Int
        let itemsPerPage: Int
        let totalItems: Int
        let totalPages: Int
    }

    /// A series from `all-v2` (`SeriesDto`). Blurb and genres are not
    /// here but on the chapter — or in `/api/Series/metadata`, which the kit does not
    /// fetch per series.
    struct Series: Decodable, Sendable {
        let id: Int
        let name: String?
        let localizedName: String?
        let sortName: String?
        let pages: Int?
        let pagesRead: Int?
        /// 0 image, 1 archive, 2 unknown, 3 EPUB, 4 PDF.
        let format: Int?
        let libraryId: Int?
        let libraryName: String?
        let createdUtc: Date?
        let lastChapterAddedUtc: Date?
        let latestReadDate: Date?
        let lastFolderScanned: Date?
    }

    /// `GET /api/Series/volumes?seriesId=` (`VolumeDto`) — with the chapters and
    /// their reading state.
    struct Volume: Decodable, Sendable {
        let id: Int
        let seriesId: Int
        let name: String?
        let minNumber: Double?
        let pages: Int?
        let createdUtc: Date?
        @Lenient var chapters: [Chapter]
    }

    /// A chapter (`ChapterDto`) — for Akari the title: file, pages
    /// and reading state hang here. A book from the books library is a volume with exactly one
    /// chapter; a manga volume as one CBZ likewise.
    struct Chapter: Decodable, Sendable {
        let id: Int
        let volumeId: Int?
        let range: String?
        let number: String?
        let minNumber: Double?
        let sortOrder: Double?
        let pages: Int?
        let isSpecial: Bool?
        let title: String?
        let titleName: String?
        let summary: String?
        let pagesRead: Int?
        let lastReadingProgressUtc: Date?
        let createdUtc: Date?
        let releaseDate: Date?
        let ageRating: Int?
        let language: String?
        let format: Int?
        let wordCount: Int64?
        let files: [FileInfo]?
        let writers: [Person]?
        let pencillers: [Person]?
        let publishers: [Person]?
        let genres: [Genre]?
        /// Kavita's tags (`TagDto`, the same shape as genres).
        let tags: [Genre]?
    }

    /// `MangaFileDto` — the file behind a chapter.
    struct FileInfo: Decodable, Sendable {
        let id: Int
        let pages: Int?
        let bytes: Int64?
        let format: Int?
        let fileExtension: String?

        enum CodingKeys: String, CodingKey {
            case id, pages, bytes, format
            case fileExtension = "extension"
        }
    }

    struct Person: Decodable, Sendable {
        let name: String?
    }

    struct Genre: Decodable, Sendable {
        let title: String?
    }

    /// `GET /api/Volume?volumeId=` — only where the volume comes from.
    struct VolumeHead: Decodable {
        let id: Int
        let seriesId: Int
        let name: String?
        let minNumber: Double?
    }

    /// `GET /api/Reader/get-progress` and the body for `POST /api/Reader/progress`
    /// (`ProgressDto`). `pageNum` counts from 0 and at the same time means "this many pages
    /// read": Kavita sets a chapter to read as soon as `pageNum` reaches the
    /// page count.
    struct Progress: Codable, Sendable {
        let volumeId: Int
        let chapterId: Int
        let pageNum: Int
        let seriesId: Int
        let libraryId: Int
        let bookScrollId: String?
        let lastModifiedUtc: String?
    }

    /// `GET /api/Rating/overall-series` (`RatingDto`): `averageScore` is the
    /// average of all accounts of this server in percent; 0 means "nobody
    /// rated". `provider` 0 is Kavita itself — external sources (AniList, MAL,
    /// Hardcover …) only come with Kavita+.
    struct Rating: Decodable {
        let averageScore: Int?
        let favoriteCount: Int?
        let provider: Int?
    }

    /// The body for `POST /api/want-to-read/add-series` and `remove-series`.
    struct WantToReadSeries: Encodable {
        let seriesIds: [Int]
    }

    /// `GET /api/Collection` (`AppUserCollectionDto`) — series, per user; what an
    /// admin "promotes" (`promoted`) is seen by all.
    struct TitleCollection: Decodable, Sendable {
        let id: Int
        let title: String?
        let promoted: Bool?
        let owner: String?
    }

    /// `POST /api/Collection/update-for-series` (`CollectionTagBulkAddDto`): id 0
    /// creates a new collection with the title.
    struct FillCollection: Encodable {
        let collectionTagId: Int
        let collectionTagTitle: String
        let seriesIds: [Int]
    }

    /// `POST /api/ReadingList/lists` (`ReadingListDto`) — chapters in order.
    struct ReadingList: Decodable, Sendable {
        let id: Int
        let title: String?
        let promoted: Bool?
        let ownerUserName: String?
    }

    /// `GET /api/ReadingList/items` (`ReadingListItemDto`).
    struct ListEntry: Decodable, Sendable {
        let id: Int
        let order: Int?
        let chapterId: Int
        let seriesId: Int?
    }

    /// `POST /api/ReadingList/create`.
    struct CreateReadingList: Encodable {
        let title: String
    }

    /// `POST /api/ReadingList/update-by-chapter`.
    struct ReadingListChapter: Encodable {
        let chapterId: Int
        let seriesId: Int
        let readingListId: Int
    }

    /// `POST /api/ReadingList/delete-item` (`UpdateReadingListPosition`) — only the
    /// two ids count when deleting.
    struct DeleteReadingListItem: Encodable {
        let readingListId: Int
        let readingListItemId: Int
        let fromPosition: Int
        let toPosition: Int
    }

    /// `GET /api/reading-profile/all` and `/api/reading-profile/{libraryId}/{seriesId}`
    /// (`UserReadingProfileDto`). Kavita carries reading direction and webtoon **not** on series
    /// or chapter but in the user's reading profile — per series, per library or as the
    /// default (`kind` 0). `readerMode` 2 is webtoon, `readingDirection` 1 right to left.
    struct ReadingProfile: Decodable, Sendable {
        let id: Int
        let kind: Int?
        let seriesIds: [Int]?
        let libraryIds: [Int]?
        let readingDirection: Int?
        let readerMode: Int?
        let allowAutomaticWebtoonReaderDetection: Bool?
    }

    /// `GET /api/Reader/file-dimensions` (`FileDimensionDto`) — the dimensions before loading.
    struct PageDimensions: Decodable {
        let pageNumber: Int
        let width: Int?
        let height: Int?
    }

    /// Kavita's time values: `2026-10-24T19:57:46.2061477` — up to seven
    /// fractional digits and **without a zone**, even on the fields called `…Utc`.
    /// The ISO reader from `ServerFetch` does not accept that; the fields without `Utc` are
    /// server time and are only read here where there is no other
    /// (`latestReadDate`). `0001-01-01T00:00:00` means "never".
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = time(text) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No date: \(text)")
            )
        }
        return decoder
    }()

    /// Reads `YYYY-MM-DDTHH:MM:SS[.f…][Z|±HH:MM]`; without a zone UTC applies.
    static func time(_ text: String) -> Date? {
        var remainder = Substring(text.trimmingCharacters(in: .whitespaces))
        var offset: TimeInterval = 0
        if remainder.hasSuffix("Z") {
            remainder = remainder.dropLast()
        } else if remainder.count > 6 {
            let zone = remainder.suffix(6)
            if let sign = zone.first, sign == "+" || sign == "-",
                zone.dropFirst(3).first == ":",
                let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2))
            {
                offset = TimeInterval(hours * 3600 + minutes * 60) * (sign == "+" ? 1 : -1)
                remainder = remainder.dropLast(6)
            }
        }
        var fraction: TimeInterval = 0
        if let dot = remainder.firstIndex(of: ".") {
            fraction = Double("0" + remainder[dot...]) ?? 0
            remainder = remainder[..<dot]
        }
        let share = remainder.split(whereSeparator: { $0 == "-" || $0 == "T" || $0 == ":" }).compactMap {
            Int($0)
        }
        guard share.count == 6 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard
            let date = calendar.date(
                from: DateComponents(
                    year: share[0], month: share[1], day: share[2], hour: share[3], minute: share[4],
                    second: share[5]))
        else { return nil }
        return date.addingTimeInterval(fraction - offset)
    }
}
