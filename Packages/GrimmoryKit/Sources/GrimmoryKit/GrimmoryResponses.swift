import Foundation
import SourcesKit

/// The responses of the Grimmory mobile API (`/api/v1/app/…`, contract: grimmory.org/api),
/// as far as the kit reads them. Names as in the JSON.
enum GrimmoryResponses {

    struct Login: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String
        /// Seconds at sign-in (7200), a timestamp in milliseconds on refresh according to the
        /// contract — ``GrimmoryAccess/flow(from:now:)`` reads both.
        let expires: Double
    }

    struct User: Decodable, Sendable {
        let id: Int
        let username: String
        let name: String?
        let permissions: Permissions

        struct Permissions: Decodable, Sendable {
            let admin: Bool
            let canDownload: Bool
        }
    }

    struct Page<Content: Decodable & Sendable>: Decodable, Sendable {
        let content: [Content]
        let page: Int
        let size: Int
        let totalElements: Int
        let hasNext: Bool
    }

    /// A book in the list — and, with `description` and `files`, in the detail.
    struct Book: Decodable, Sendable {
        let id: Int
        let title: String
        let subtitle: String?
        let authors: [String]?
        let description: String?
        let readStatus: String?
        let readProgress: Double?
        let lastReadTime: Date?
        let seriesName: String?
        let seriesNumber: Double?
        let seriesTotal: Int?
        let addedOn: Date
        let publishedDate: String?
        let primaryFileType: String?
        let publisher: String?
        let categories: [String]?
        let language: String?
        let narrator: String?
        let pageCount: Int?
        let ageRating: Int?
        let fileSizeKb: Int64?
        let goodreadsRating: Double?
        let goodreadsReviewCount: Int?
        let amazonRating: Double?
        let amazonReviewCount: Int?
        let epubProgress: EpubProgress?
        let pdfProgress: PageProgress?
        let cbxProgress: PageProgress?
        let audiobookProgress: AudioProgress?
    }

    /// A page from `GET /api/v1/books/page` — up to 1,000 books, with the total.
    struct BookPage: Decodable, Sendable {
        let content: Lenient<WebBook>
        let page: PageInfo

        struct PageInfo: Decodable, Sendable {
            let totalElements: Int
        }
    }

    /// A book of the web list `GET /api/v1/books` — all at once, metadata nested, reading
    /// state on the book where there is one.
    struct WebBook: Decodable, Sendable {
        let id: Int
        let libraryId: Int?
        let addedOn: Date
        let metadata: BookMetadata
        let primaryFile: FileInfo?
        let readStatus: String?
        let lastReadTime: Date?
        let epubProgress: EpubProgress?
        let pdfProgress: PageProgress?
        let cbxProgress: PageProgress?
        let audiobookProgress: AudioProgress?

        struct BookMetadata: Decodable, Sendable {
            let title: String
            let subtitle: String?
            /// Only in the response with `?withDescription=true` (Grimmory `BookController`).
            let description: String?
            let authors: [String]?
            let categories: [String]?
            let seriesName: String?
            let seriesNumber: Double?
            /// How long the series is — only in the unabridged list (`stripForListView=false`).
            let seriesTotal: Int?
            let publishedDate: String?
            let pageCount: Int?
            let language: String?
            let publisher: String?
            let narrator: String?
            let ageRating: Int?
            let goodreadsRating: Double?
            let goodreadsReviewCount: Int?
            let amazonRating: Double?
            let amazonReviewCount: Int?
        }

        struct FileInfo: Decodable, Sendable {
            let bookType: String?
            let fileSizeKb: Int64?
        }

        /// The same book in the shape of the mobile list — one mapping for both.
        var asBook: Book {
            Book(
                id: id, title: metadata.title, subtitle: metadata.subtitle, authors: metadata.authors,
                description: metadata.description,
                readStatus: readStatus, readProgress: nil, lastReadTime: lastReadTime,
                seriesName: metadata.seriesName,
                seriesNumber: metadata.seriesNumber, seriesTotal: metadata.seriesTotal, addedOn: addedOn,
                publishedDate: metadata.publishedDate,
                primaryFileType: primaryFile?.bookType,
                publisher: metadata.publisher, categories: metadata.categories, language: metadata.language,
                narrator: metadata.narrator, pageCount: metadata.pageCount, ageRating: metadata.ageRating,
                fileSizeKb: primaryFile?.fileSizeKb, goodreadsRating: metadata.goodreadsRating,
                goodreadsReviewCount: metadata.goodreadsReviewCount, amazonRating: metadata.amazonRating,
                amazonReviewCount: metadata.amazonReviewCount, epubProgress: epubProgress,
                pdfProgress: pdfProgress,
                cbxProgress: cbxProgress, audiobookProgress: audiobookProgress)
        }
    }

    /// `GET /api/v1/authors` (list: without `description`) and `/api/v1/authors/{id}`
    /// (detail: with) — Grimmory 3.3.3, `AuthorSummary`/`AuthorDetails`.
    struct Author: Decodable, Sendable {
        let id: Int
        let name: String
        let description: String?
        let bookCount: Int?
        let hasPhoto: Bool?
    }

    /// `GET /api/v1/app/books/{id}/progress` — empty (`{}`) if never opened.
    struct Progress: Decodable, Sendable {
        let readProgress: Double?
        let readStatus: String?
        let lastReadTime: Date?
        let epubProgress: EpubProgress?
        let pdfProgress: PageProgress?
        let cbxProgress: PageProgress?
        let audiobookProgress: AudioProgress?
    }

    struct EpubProgress: Codable, Sendable {
        let cfi: String?
        let href: String?
        /// 0 … 100.
        let percentage: Double
    }

    struct PageProgress: Codable, Sendable {
        let page: Int
        let percentage: Double
    }

    struct AudioProgress: Codable, Sendable {
        let positionMs: Int64
        let percentage: Double
    }

    /// `PUT /api/v1/app/books/{id}/progress` — exactly one branch set.
    struct ProgressReport: Encodable {
        var epubProgress: EpubProgress?
        var pdfProgress: PageProgress?
        var cbxProgress: PageProgress?
        var audiobookProgress: AudioProgress?
        var dateFinished: String?
    }

    /// `PUT /api/v1/app/books/{id}/status` — `UNREAD`, `READING`, `READ`, …
    struct StatusReport: Encodable {
        let status: String
    }

    /// `GET /api/v1/app/shelves` and `GET /api/v1/shelves` — the user's shelves; "Favorites" is
    /// the shelf Grimmory creates for every account and the app uses as the saved list. The web
    /// list also carries `userId` and `publicShelf`.
    struct Shelf: Decodable, Sendable {
        let id: Int
        let name: String
        let icon: String?
        let userId: Int?
        let publicShelf: Bool?
    }

    /// `GET /api/v1/shelves/{id}/books` — the web books on the shelf; only the id is needed.
    struct ShelfBook: Decodable, Sendable {
        let id: Int
    }

    /// `GET /api/v1/libraries` — the server's libraries.
    struct LibraryInfo: Decodable, Sendable {
        let id: Int
        let name: String
    }

    /// `GET /api/v1/app/books?sort=lastReadTime&dir=desc` — the most recently read; only id,
    /// status and time are needed; `/progress` fetches the state itself.
    struct ReadTimePage: Decodable, Sendable {
        let content: [ReadTime]

        struct ReadTime: Decodable, Sendable {
            let id: Int
            let readStatus: String?
            let lastReadTime: Date?
        }
    }

    /// `GET /api/v1/app/shelves/magic` — the Magic Shelves, filled by rules.
    struct MagicShelf: Decodable, Sendable {
        let id: Int
        let name: String
        let icon: String?
        let publicShelf: Bool?
    }

    /// `GET /api/v1/app/shelves/magic/{id}/books` — a page of at most 50 books; only the ids and
    /// the total are needed.
    struct MagicPage: Decodable, Sendable {
        let content: [ShelfBook]
        let totalElements: Int
    }

    /// `POST /api/v1/shelves` — a new shelf if "Favorites" is missing.
    struct CreateShelf: Encodable {
        let name: String
        let icon: String
        let iconType: String
        let publicShelf: Bool
    }

    /// `POST /api/v1/books/shelves` — put books onto shelves and take them off.
    struct ShelfAssignment: Encodable {
        let bookIds: [Int]
        let shelvesToAssign: [Int]
        let shelvesToUnassign: [Int]
    }

    struct LoginBody: Encodable {
        let username: String
        let password: String
    }

    struct RefreshBody: Encodable {
        let refreshToken: String
    }
}
