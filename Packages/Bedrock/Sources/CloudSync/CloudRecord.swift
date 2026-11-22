import Foundation

/// A field of a record: the value types CloudKit carries without detour (text,
/// integer, decimal number, point in time, bytes). A truth is a number in
/// CloudKit; ``truth`` therefore also reads `integer(0)` and `integer(1)`.
public enum FieldValue: Sendable, Hashable, Codable {
    case text(String)
    case integer(Int)
    case decimalNumber(Double)
    case time(Date)
    case truth(Bool)
    case data(Data)

    public var text: String? {
        if case .text(let t) = self { return t }
        return nil
    }

    public var integer: Int? {
        switch self {
        case .integer(let z): z
        case .decimalNumber(let k): Int(k)
        case .truth(let w): w ? 1 : 0
        default: nil
        }
    }

    public var decimalNumber: Double? {
        switch self {
        case .decimalNumber(let k): k
        case .integer(let z): Double(z)
        default: nil
        }
    }

    public var time: Date? {
        if case .time(let z) = self { return z }
        return nil
    }

    public var truth: Bool? {
        switch self {
        case .truth(let w): w
        case .integer(let z): z != 0
        default: nil
        }
    }

    public var data: Data? {
        if case .data(let d) = self { return d }
        return nil
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case text
        case integer = "zahl"
        case decimalNumber = "kommazahl"
        case time = "zeit"
        case truth = "wahrheit"
        case data = "daten"
    }
    enum TextCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
    enum NumberCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
    enum DecimalNumberCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
    enum TimeCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
    enum TruthCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
    enum DataCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
}

/// Type and name together: the address of a record in its zone.
public struct RecordName: Sendable, Hashable, Codable {
    public let type: String
    public let name: String

    public init(type: String, name: String) {
        self.type = type
        self.name = name
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type = "typ"
        case name
    }
}

/// A record as the zone holds it: type, name (the `recordName`, chosen by the
/// packages above so that the same value gets the same name on two devices,
/// otherwise there would be duplicates instead of conflicts), the fields, and
/// ``changed`` as the clock by which "the younger change wins" is decided.
///
/// ``seal`` is what CloudKit knows about the record (the system fields with the
/// change tag of the server). Without a seal the record is new to the server;
/// with a seal it is a change request, which the server accepts only if it still
/// has the state (`ifServerRecordUnchanged`). The packages above never set it
/// themselves.
///
/// ``creator`` is the Apple ID that created the record (`___createdBy`, the
/// record name of the user). The server sets it, the packages only read it. That
/// lets a `Geraet` record be assigned to a participant of the share, whose
/// identity Apple otherwise does not reveal for a share via link.
public struct CloudRecord: Sendable, Hashable, Codable, Identifiable {
    public let type: String
    public let name: String
    public var fields: [String: FieldValue]
    public var changed: Date
    public var seal: Data?
    public var creator: String?

    /// Which fields are transferred **encrypted** (`CKRecord.encryptedValues`).
    ///
    /// **A field is either encrypted or not, and that forever.** Apple: *"Existing
    /// fields in a CloudKit schema are not eligible for encryption."* Whoever first
    /// stores a password in plain text and wants to encrypt it later must create a
    /// **new field**; the old one stays in the container, and containers are not
    /// deleted. This set is therefore fixed on the very first write of a kind and
    /// not touched afterwards.
    ///
    /// **Not allowed to be encrypted** are references (`CKReference`) and everything
    /// searched or sorted by: an encrypted field carries no index. ``changed``
    /// therefore always stays in plain text; it is the clock of the ``MergeRule``,
    /// and in the dashboard it is the first thing one looks at.
    ///
    /// **When reading, ``CloudKitService`` fills it from the record itself.** The
    /// caller therefore need not know what was once created encrypted; it finds out.
    public var encrypted: Set<String>

    /// When the **server** last wrote this record, `nil` as long as it exists only in
    /// the mirror.
    ///
    /// **``changed`` is the clock of the writing device and is no good as a
    /// deadline.** It goes out as an ordinary field (``CloudKitService``) and thus
    /// carries exactly the time that was set there. For the merge rule that is
    /// right: it asks "who was last", and there the human's intent counts. For a
    /// **deadline** it is wrong: whoever computes it against a clock the same human
    /// can set has no deadline.
    ///
    /// The case that decided this is the "forgot PIN" way out on the television: the
    /// system clock of tvOS sits in **its** settings and not behind the app's
    /// parental controls, and a child sets it a day ahead in two minutes.
    ///
    /// The field is filled only on reading, from `CKRecord.modificationDate`. It
    /// **never** goes out: a value the device could set would again be the device's
    /// clock.
    public var serverTime: Date?

    public init(
        type: String, name: String, fields: [String: FieldValue], changed: Date = Date(), seal: Data? = nil,
        creator: String? = nil, encrypted: Set<String> = [], serverTime: Date? = nil
    ) {
        self.type = type
        self.name = name
        self.fields = fields
        self.changed = changed
        self.seal = seal
        self.creator = creator
        self.encrypted = encrypted
        self.serverTime = serverTime
    }

    /// **Read by hand, and only because of one line.**
    ///
    /// ``encrypted`` was added later. On devices running an earlier build the mirror
    /// lies as a file **without** this field; the decoding generated by Swift demands
    /// every key and would have failed at exactly this point. The whole mirror would
    /// be unreadable, and with it the queue: everything a device wrote without
    /// network and could not yet send.
    ///
    /// A `decodeIfPresent` costs these twenty lines and prevents that.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        fields = try container.decode([String: FieldValue].self, forKey: .fields)
        changed = try container.decode(Date.self, forKey: .changed)
        seal = try container.decodeIfPresent(Data.self, forKey: .seal)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        encrypted =
            try container.decodeIfPresent(Set<String>.self, forKey: .encrypted) ?? []
        serverTime = try container.decodeIfPresent(Date.self, forKey: .serverTime)
    }

    public var id: RecordName { RecordName(type: type, name: name) }

    public subscript(field: String) -> FieldValue? {
        get { fields[field] }
        set { fields[field] = newValue }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case type = "typ"
        case name
        case fields = "felder"
        case changed = "geaendert"
        case seal = "siegel"
        case creator = "ersteller"
        case encrypted = "verschluesselt"
        case serverTime = "serverzeit"
    }
}

/// A zone: its name and, for a foreign one, whom it belongs to. The own zone is
/// in the private database (``owner`` `nil`), an accepted share in the shared
/// database under the record name of the owner.
public struct ZoneID: Sendable, Hashable, Codable {

    /// Every profile zone is called `profil-<identifier>`. The identifier is a UUID
    /// the profile gets on first binding and never changes (renaming leaves the zone
    /// in place; the name was only the crutch of the key store).
    public static let leadIn = "profil-"

    public let name: String
    public let owner: String?

    /// CloudKit's name for **the own account** (`CKCurrentUserDefaultName`).
    ///
    /// **The finding:** Apple TV and iPhone with the same Apple ID. The phone
    /// accepted the share of a profile that belongs to itself; CloudKit named
    /// `__defaultOwner__` as the owner, and because every identifier with an owner
    /// counted as ``shared``, the mirror asked the **shared** database: "Only shared
    /// zones can be accessed in the shared DB" (CKError 12), at every pass. Of the
    /// profile only the name arrived. The own account is not a foreign owner.
    public static let ownAccount = "__defaultOwner__"

    public init(name: String, owner: String? = nil) {
        self.name = name
        self.owner = owner == Self.ownAccount ? nil : owner
    }

    /// A stored mirror that already carries the placeholder also reads correctly.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            owner: try container.decodeIfPresent(String.self, forKey: .owner))
    }

    private enum CodingKeys: String, CodingKey { case name, owner = "besitzer" }

    public init(profile identifier: UUID, owner: String? = nil) {
        self.init(name: ZoneID.leadIn + identifier.uuidString.lowercased(), owner: owner)
    }

    public var shared: Bool { owner != nil }

    /// Whether it is a profile zone; the shared database can carry other things too.
    public var isProfile: Bool { name.hasPrefix(ZoneID.leadIn) }
}

/// The rule by which two versions of the same record become one: one's own
/// request against what the server has in the meantime.
public struct MergeRule: Sendable {
    public let merge: @Sendable (_ own: CloudRecord, _ server: CloudRecord) -> CloudRecord

    public init(_ merge: @escaping @Sendable (CloudRecord, CloudRecord) -> CloudRecord) {
        self.merge = merge
    }

    /// The younger change wins: settings, bookmarks.
    public static let younger = MergeRule { own, server in
        own.changed >= server.changed ? own : server
    }

    /// The larger value of a field wins: for sessions the later end (the running
    /// audiobook session grows); with an equal value the younger change.
    public static func largerValue(_ field: String) -> MergeRule {
        MergeRule { own, server in
            let e = own[field]?.time?.timeIntervalSince1970 ?? own[field]?.decimalNumber ?? 0
            let s = server[field]?.time?.timeIntervalSince1970 ?? server[field]?.decimalNumber ?? 0
            if e != s { return e > s ? own : server }
            return MergeRule.younger.merge(own, server)
        }
    }
}
