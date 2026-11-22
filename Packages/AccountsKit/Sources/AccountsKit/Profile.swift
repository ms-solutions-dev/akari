import CloudSync
import Foundation

/// A reader on this device — a name with an initial, and underneath everything that
/// used to be "the one sign-in": accounts, saved list, local reading states, reading
/// statistics, theme and language.
///
/// **A profile is a prefix, not an account.** It has no Apple ID and no server user;
/// it only says under which key and in which folder this reader's things live
/// (``ProfileStore``). The identifier is a running number: profile 1 is always what
/// existed before profiles — so every key stays readable (`profil.1.konto.komga`),
/// and a deleted number is never reissued.
///
/// **The color is a theme name**, not a color value: the package does not know the
/// design system, the UI resolves `tinte`/`terrakotta`/`indigo`/`pflaume` itself. An
/// unknown name falls back to the default.
///
/// **The PIN is not stored here** but as a salted SHA-256 in the keychain
/// (``PinProtection``); ``protected`` is only the mirror for the UI.
///
/// **The CloudKit zone** hangs on the identifier, not on the name: ``cloud`` is the
/// zone once the profile has been bound — its own in the private database, or for an
/// accepted profile the owner's in the shared one (``shared``, ``sharedBy``).
/// Renaming leaves it alone. ``cloudSync`` is the reader's switch: off means local
/// only, no zone.
public struct Profile: Sendable, Hashable, Codable, Identifiable {
    public let id: Int
    public var name: String
    public var color: String
    /// The maximum age of a child profile — `nil` means: no child, everything visible.
    public var maxAge: Int?
    /// Whether switching to this profile requires a PIN.
    public var protected: Bool
    public let created: Date
    /// The profile's zone in CloudKit — `nil` while none is bound.
    public var cloud: ZoneID?
    /// Who shared the zone — only for an accepted profile.
    public var sharedBy: String?
    /// Whether the reader wants sync via iCloud for this profile (default: yes).
    public var cloudSync: Bool

    /// The three levels "For a child" offers — Komga knows 10–18, ABS only "explicit"
    /// (= 18); 6/12/16 are the FSK levels parents know here.
    public static let ageLevels = [6, 12, 16]

    public init(
        id: Int, name: String, color: String, maxAge: Int? = nil, protected: Bool = false,
        created: Date = Date(), cloud: ZoneID? = nil, sharedBy: String? = nil,
        cloudSync: Bool = true
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.maxAge = maxAge
        self.protected = protected
        self.created = created
        self.cloud = cloud
        self.sharedBy = sharedBy
        self.cloudSync = cloudSync
    }

    /// Lists from before cloud sync do not know the three cloud fields — they stay readable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(String.self, forKey: .color)
        maxAge = try c.decodeIfPresent(Int.self, forKey: .maxAge)
        protected = try c.decodeIfPresent(Bool.self, forKey: .protected) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        cloud = try c.decodeIfPresent(ZoneID.self, forKey: .cloud)
        sharedBy = try c.decodeIfPresent(String.self, forKey: .sharedBy)
        cloudSync = try c.decodeIfPresent(Bool.self, forKey: .cloudSync) ?? true
    }

    /// Whether this is an accepted profile — the zone belongs to another Apple ID.
    public var shared: Bool { cloud?.shared == true }

    /// The first character of the name, uppercase — "A" for Alice; an empty name gives
    /// a question mark so the circle is never empty.
    public var initial: String {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() }
        return initial ?? "?"
    }

    /// Whether this is a child profile — the shelf filters, the UI hides.
    public var kind: Bool { maxAge != nil }

    /// The prefix under which everything of this profile lives in the keychain and in
    /// UserDefaults: `profil.<id>.`.
    public var prefix: String { Profile.prefix(id) }

    public static func prefix(_ id: Int) -> String { "profil.\(id)." }

    /// The name of the old iCloud keys (formerly `profil.<name>.gemerkt`) — lowercase,
    /// without margin, whitespace as dash. Only still needed for the transition into the
    /// zone; the zone itself hangs on the identifier (``cloud``).
    public var cloudName: String { Profile.cloudName(name) }

    public static func cloudName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case color = "farbe"
        case maxAge = "hoechstalter"
        case protected = "geschuetzt"
        case created = "angelegt"
        case cloud = "wolke"
        case sharedBy = "geteiltVon"
        case cloudSync = "wolkenabgleich"
    }
}
