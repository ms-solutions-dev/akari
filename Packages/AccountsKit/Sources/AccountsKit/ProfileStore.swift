import Foundation

/// Where the things of a profile live — the one answer to "under which key, in which
/// folder", so no package assembles the prefix itself.
///
/// Three places, one profile:
/// - **Keychain:** `profil.<id>.konto.komga`, `profil.<id>.pin` — the ``prefix`` in
///   front of every key that ``AccountStore`` used to write bare.
/// - **UserDefaults:** its own suite per profile (`…akari.profil.<id>`), not a prefix
///   per key — that way `@AppStorage` picks it up via `defaultAppStorage` without
///   every view rebuilding its key, and "remove profile" is one
///   `removePersistentDomain` instead of a search for keys with a prefix.
/// - **Files:** `Application Support/profile/<id>/` with `bestand`, `fortschritt`,
///   `staende` and `lesezeit.json`.
///
/// The stock (downloads, cache) and the device files do **not** live here — they are
/// shared, one file for all.
///
public struct ProfileStore: Sendable, Hashable {
    public let profile: Int
    /// The name of the UserDefaults suite — as a name, not an object, so "remove profile"
    /// can wipe the suite entirely with `removePersistentDomain`.
    public let suite: String
    public let folder: URL

    /// - Parameters:
    ///   - suite: the profile's suite; tests pass their own
    ///   - folder: the profile's folder; tests pass one under `tmp`
    public init(profile: Int, suite: String? = nil, folder: URL? = nil) {
        self.profile = profile
        self.suite = suite ?? ProfileStore.suite(profile)
        self.folder = folder ?? ProfileStore.root.appending(path: "\(profile)", directoryHint: .isDirectory)
    }

    /// The profile's UserDefaults.
    public var settings: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    /// `profil.<id>.` — in front of every keychain key.
    public var prefix: String { Profile.prefix(profile) }

    /// The name of this profile's UserDefaults suite.
    public static func suite(_ profile: Int) -> String { "dev.ms-solutions.akari.profil.\(profile)" }

    /// `Application Support/profile` — one folder per profile below it.
    public static var root: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appending(path: "profile", directoryHint: .isDirectory)
    }

    // MARK: - The subfolders

    /// The excerpts of the sources (the inventory store in `Library`).
    public var inventory: URL { folder.appending(path: "bestand", directoryHint: .isDirectory) }
    /// The catalog of all sources (the catalog index in `Library`).
    public var catalog: URL { folder.appending(path: "katalog").appendingPathExtension("sqlite") }
    /// The queue and the device trail (`ReadingProgress`).
    public var progress: URL { folder.appending(path: "fortschritt", directoryHint: .isDirectory) }
    /// The local reading states of the sources without a server-side state (OPDS, WebDAV).
    public var states: URL { folder.appending(path: "staende", directoryHint: .isDirectory) }
    /// The reading-time log.
    public var readingTime: URL { folder.appending(path: "lesezeit.json") }
    /// The mirror of the CloudKit zone: records, queue, marker.
    public var cloud: URL { folder.appending(path: "wolke.json") }
}
