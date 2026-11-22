import Foundation
import SourcesKit

/// The responses of Komga 1.26, as far as the kit reads them — fields missing here
/// are ignored by the decoder. Names as in the JSON, so the recording in `Fixtures`
/// and the source speak the same language.
enum KomgaResponses {

    /// A page of a list (`Page<T>` in Spring).
    struct Page<Element: Decodable & Sendable>: Decodable {
        /// Lenient: an unreadable book is missing on its own instead of failing the whole
        /// page and with it the whole catalog.
        @Lenient var content: [Element]
        let totalElements: Int
        let last: Bool
        let number: Int
    }

    struct User: Decodable {
        let id: String
        let email: String
        let roles: [String]
    }

    struct ApiKey: Decodable {
        let id: String
        let key: String
        let comment: String
    }

    struct Author: Decodable {
        let name: String
        let role: String
    }

    struct Series: Decodable {
        let id: String
        let name: String
        let booksCount: Int
        let created: Date
        let metadata: Metadata
        let booksMetadata: BooksMetadata

        struct Metadata: Decodable {
            let title: String
            let summary: String
            let readingDirection: String?
            let publisher: String
            let ageRating: Int?
            let language: String
            let genres: [String]
            let tags: [String]
            /// `ONGOING`, `ENDED`, `HIATUS`, `ABANDONED` — maintained by komf.
            let status: String?
            /// How many volumes the run has — not how many are on the shelf.
            let totalBookCount: Int?
        }

        struct BooksMetadata: Decodable {
            let authors: [Author]
        }
    }

    /// A page in the manifest (`GET /api/v1/books/{id}/pages`) — the dimensions before
    /// loading. `width`/`height` are missing if Komga never analyzed the image.
    struct PageDimensions: Decodable {
        let number: Int
        let width: Int?
        let height: Int?
    }

    struct Book: Decodable {
        let id: String
        let seriesId: String
        let seriesTitle: String
        let name: String
        let created: Date
        let sizeBytes: Int64
        let media: Medium
        let metadata: Metadata
        let readProgress: ReadProgress?

        struct Medium: Decodable {
            let pagesCount: Int
            let mediaProfile: String
            /// `application/zip`, `application/x-rar-compressed; version=4`,
            /// `application/epub+zip`, `application/pdf` — the file's format.
            let mediaType: String?
        }

        struct Metadata: Decodable {
            let title: String
            let summary: String
            let numberSort: Double
            let authors: [Author]
            let releaseDate: String?
        }
    }

    struct ReadProgress: Decodable {
        let page: Int
        let completed: Bool
        let readDate: Date
        let lastModified: Date
        let deviceName: String
    }

    /// The body for `PATCH /api/v1/books/{id}/read-progress`.
    struct ProgressReport: Encodable {
        let page: Int
        let completed: Bool
    }

    struct CreateAuthKey: Encodable {
        let comment: String
    }

    /// `GET /api/v1/collections` — sets of series, library-wide; the ids
    /// are included right away (`CollectionDto`, Komga OpenAPI).
    struct TitleCollection: Decodable, Sendable {
        let id: String
        let name: String
        let ordered: Bool
        let seriesIds: [String]
    }

    /// `GET /api/v1/readlists` — ordered sequences of volumes (`ReadListDto`).
    struct ReadingList: Decodable, Sendable {
        let id: String
        let name: String
        let ordered: Bool
        let bookIds: [String]
    }

    struct CreateCollection: Encodable {
        let name: String
        let ordered: Bool
        let seriesIds: [String]
    }

    struct CreateReadingList: Encodable {
        let name: String
        let summary: String
        let ordered: Bool
        let bookIds: [String]
    }

    struct ChangeCollection: Encodable {
        let seriesIds: [String]
    }

    struct ChangeReadingList: Encodable {
        let bookIds: [String]
    }
}
