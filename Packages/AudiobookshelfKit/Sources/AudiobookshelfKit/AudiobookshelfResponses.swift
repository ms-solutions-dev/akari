import Foundation
import SourcesKit

/// The responses of Audiobookshelf, as far as the kit reads them. The list delivers
/// metadata "minified" (`authorName`, `seriesName` as `Name #1`), the detail with
/// `expanded=1` the fields as lists — both shapes stand side by side here.
enum AudiobookshelfResponses {

    struct SignInResponse: Decodable, Sendable {
        let user: User
    }

    struct User: Decodable, Sendable {
        let id: String
        let username: String
        let token: String?
        let mediaProgress: [Progress]
        let permissions: Permissions

        struct Permissions: Decodable, Sendable {
            let download: Bool
        }
    }

    struct Libraries: Decodable, Sendable {
        let libraries: [Library]
    }

    struct Library: Decodable, Sendable {
        let id: String
        let name: String
        let mediaType: String
    }

    /// `GET /api/libraries/{id}/recent-episodes` — the latest episodes of a
    /// podcast library across all podcasts, descending by release, with the
    /// podcast title on every episode.
    struct LatestEpisodes: Decodable, Sendable {
        let episodes: [Episode]

        struct Episode: Decodable, Sendable {
            let id: String
            let libraryItemId: String
            let title: String
            let addedAt: Double?
            let publishedAt: Double?
            let podcast: Podcast?
        }

        struct Podcast: Decodable, Sendable {
            let metadata: Metadata
        }

        struct Metadata: Decodable, Sendable {
            let title: String
        }
    }

    struct ItemList: Decodable, Sendable {
        /// Lenient: an unreadable entry is missing on its own (``Lenient``).
        @Lenient var results: [Item]
        let total: Int
        let page: Int
        let limit: Int
    }

    struct Item: Decodable, Sendable {
        let id: String
        let libraryId: String
        /// `book` or `podcast`.
        let mediaType: String?
        /// Milliseconds since 1970.
        let addedAt: Double
        /// All files of the title together, in bytes.
        let size: Int64?
        let media: Medium

        struct Medium: Decodable, Sendable {
            let metadata: Metadata
            let duration: Double?
            let numChapters: Int?
            let tags: [String]?
            let chapters: [Chapter]?
            /// The list gives the e-book format flat (`epub`), the detail in `ebookFile`.
            let ebookFormat: String?
            let ebookFile: Ebook?
            /// The tracks, only with `expanded=1` — one per file, with their position in the whole.
            let tracks: [Track]?
            /// Podcast: how many episodes the server has — the episodes themselves only in the detail.
            let numEpisodes: Int?
            /// Podcast, only with `expanded=1`: the episodes with file, duration and date.
            let episodes: [Episode]?
        }

        /// A podcast episode. `episode`/`season` come from the feed as text and
        /// are often empty; `publishedAt` (milliseconds) is always there and orders.
        struct Episode: Decodable, Sendable {
            let id: String
            let libraryItemId: String
            let title: String
            let subtitle: String?
            let description: String?
            let episode: String?
            let season: String?
            let publishedAt: Double?
            let addedAt: Double?
            let duration: Double?
            let size: Int64?
            let chapters: [Chapter]?
            /// The file as a track — `contentUrl` is `/api/items/{item}/file/{ino}`.
            let audioTrack: Track?
        }

        struct Track: Decodable, Sendable {
            let index: Int
            let startOffset: Double
            let duration: Double
            let contentUrl: String
            let metadata: FileInfo?

            struct FileInfo: Decodable, Sendable {
                /// `.mp3`, `.m4b` — only in the detail.
                let ext: String?
                /// Bytes of the file — the sum is on the button before keeping.
                let size: Int64?
            }
        }

        struct Metadata: Decodable, Sendable {
            let title: String
            let subtitle: String?
            let authorName: String?
            /// Podcast: the publisher from the feed — a name, not a list.
            let author: String?
            let narratorName: String?
            let seriesName: String?
            let authors: [Person]?
            let narrators: [String]?
            let series: [BookSeries]?
            let genres: [String]?
            let publisher: String?
            let publishedYear: String?
            let description: String?
            let language: String?
            let explicit: Bool?
        }

        struct Person: Decodable, Sendable {
            let name: String
        }

        struct BookSeries: Decodable, Sendable {
            let id: String
            let name: String
            let sequence: String?
        }

        struct Chapter: Decodable, Sendable {
            let start: Double
            let end: Double
            let title: String
        }

        struct Ebook: Decodable, Sendable {
            let ebookFormat: String?
        }
    }

    struct Progress: Decodable, Sendable {
        /// The entry's own id — only `DELETE /api/me/progress/{id}` wants it.
        let id: String
        let libraryItemId: String
        /// Set if the state belongs to a podcast episode.
        let episodeId: String?
        let duration: Double
        let progress: Double
        let currentTime: Double
        let isFinished: Bool
        /// Milliseconds since 1970.
        let lastUpdate: Double
    }

    /// `PATCH /api/me/progress/{itemId}`.
    struct ProgressReport: Encodable {
        let currentTime: Double
        let duration: Double
        let progress: Double
        let isFinished: Bool
    }

    struct SignInBody: Encodable {
        let username: String
        let password: String
    }

    /// `GET /api/collections` — library-wide, with the books as entries.
    struct CollectionList: Decodable, Sendable {
        let collections: [TitleCollection]
    }

    struct TitleCollection: Decodable, Sendable {
        let id: String
        let libraryId: String
        let userId: String?
        let name: String
        let books: [Reference]?

        struct Reference: Decodable, Sendable {
            let id: String
        }
    }

    /// `GET /api/playlists` — the user's playlists, in order.
    struct PlaylistList: Decodable, Sendable {
        let playlists: [Playlist]
    }

    struct Playlist: Decodable, Sendable {
        let id: String
        let libraryId: String
        let userId: String?
        let name: String
        let items: [Entry]?

        struct Entry: Decodable, Sendable {
            let libraryItemId: String
        }
    }

    struct CreateCollection: Encodable {
        let libraryId: String
        let name: String
    }

    struct CreatePlaylist: Encodable {
        let libraryId: String
        let name: String
        let items: [Entry]
        struct Entry: Encodable {
            let libraryItemId: String
        }
    }

    struct BookReference: Encodable {
        let id: String
    }

    struct ItemReference: Encodable {
        let libraryItemId: String
    }
}
