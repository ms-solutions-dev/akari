import Foundation

/// The "Continue reading" snapshot as the app stores it for the widget: up to
/// four started titles of the **active** profile, the most recent first — the same
/// order as the row on the start page.
///
/// **Why a value of its own and not the shelf:** the widget runs in a different
/// process and may not ask a server, read a keychain, or
/// compute every second. It reads a JSON file and four small images from the
/// app group — it knows no more, and needs to know no more. The app
/// rewrites after every progress change, after refreshing and on
/// profile change.
public struct ContinueReadingSnapshot: Codable, Sendable, Equatable {

    /// The kind of a title — the same raw values as `SourcesKit.Kind`, so the app
    /// translates it without a table; explained once more here because the widget does not
    /// know the package and only needs to know whether the cover is portrait or square.
    public enum Kind: String, Codable, Sendable {
        case manga, book = "buch", audiobook = "hoerbuch", podcast

        /// Audiobook and podcast — square cover, headphones symbol.
        public var isAudible: Bool { self == .audiobook || self == .podcast }
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        /// The title id as text (`komga@comics.example/0K3…`) — the cover's
        /// file name hangs on it.
        public let id: String
        public let name: String
        /// Author, or series with volume — what the tile shows on the start page as a secondary line.
        public let subline: String?
        public let kind: Kind
        /// 0 … 1, as the bar shows it.
        public let fraction: Double
        /// The state in words, as the app prints it — "p. 63/205", "62 %", "3 h 12 min
        /// left"; for the lock screen, where no bar has room.
        public let state: String?
        /// `akari://lesen/…` — the tap leads directly into the reader.
        public let link: URL
        /// The file name of the cover in the snapshot folder, `nil` without a cover.
        public let cover: String?

        public init(
            id: String, name: String, subline: String?, kind: Kind, fraction: Double, state: String? = nil,
            link: URL, cover: String?
        ) {
            self.id = id
            self.name = name
            self.subline = subline
            self.kind = kind
            self.fraction = min(max(fraction, 0), 1)
            self.state = state
            self.link = link
            self.cover = cover
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case id
            case name
            case subline = "unterzeile"
            case kind = "art"
            case fraction = "anteil"
            case state = "stand"
            case link
            case cover
        }
    }

    /// The name of the profile whose titles these are — the widget names it when
    /// more than one profile exists, so it is clear on the family iPad whose book
    /// this is.
    public let profile: String
    public let multipleProfiles: Bool
    public let entries: [Item]
    public let written: Date

    /// No family shows more than four; the medium widget shows three, the small one.
    public static let cap = 4

    public init(
        profile: String, multipleProfiles: Bool = false, entries: [Item], written: Date = Date()
    ) {
        self.profile = profile
        self.multipleProfiles = multipleProfiles
        self.entries = Array(entries.prefix(ContinueReadingSnapshot.cap))
        self.written = written
    }

    /// The empty snapshot — "Nothing started yet" with the open link.
    public static func empty(profile: String, multipleProfiles: Bool = false) -> ContinueReadingSnapshot {
        ContinueReadingSnapshot(profile: profile, multipleProfiles: multipleProfiles, entries: [])
    }

    /// The file name of a cover: the hash of the id, so the folder does not carry the
    /// name of the home server (as with the image loader) — with `.jpg`, because the
    /// widget recognizes the file as an image by its extension.
    public static func coverFilename(for id: String) -> String {
        ShortHash.hex(id) + ".jpg"
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case profile = "profil"
        case multipleProfiles = "mehrereProfile"
        case entries = "eintraege"
        case written = "geschrieben"
    }
}
