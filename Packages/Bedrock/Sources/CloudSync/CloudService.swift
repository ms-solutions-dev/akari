import Foundation

/// Whether an iCloud account is present: `CKContainer.accountStatus`, reduced to four answers.
public enum AccountStatus: Sendable, Hashable {
    case available
    case noAccount
    /// Restricted (parental controls, profile) or temporarily indeterminable.
    case restricted
    case unknown
}

/// What makes a pass to the server fail: the classes the zone reacts to.
/// ``temporary`` means "try again later"; everything else needs a human (no
/// account, zone gone, rejected).
public enum CloudError: Error, Sendable, Hashable {
    case noAccount
    case unreachable
    /// The zone no longer exists (for this account): deleted, or the share was
    /// withdrawn (`CKError.zoneNotFound`).
    case zoneMissing
    /// **The human deleted the data themselves:** iOS Settings → Apple Account →
    /// iCloud → Manage Storage → App → "Delete Data" (`CKError.userDeletedZone`).
    ///
    /// **A case of its own and not ``zoneMissing``:** the dialog promises "delete on
    /// all devices", and Apple requires that the app then discards its local data or
    /// asks before it uploads anything anew. Until then the ``ProfileZone`` recreated
    /// a missing zone and wrote the mirror back up: the deletion was taken back on
    /// the next pass.
    case deletedByUser
    /// The server says no: rights, quota, schema (field unknown in production).
    case rejected(String)
    case miscellaneous(String)

    public var temporary: Bool {
        switch self {
        case .unreachable, .miscellaneous: true
        case .noAccount, .zoneMissing, .deletedByUser, .rejected: false
        }
    }
}

/// Why a zone this device already knew has vanished: the reason that
/// ``ProfileZone/onRemoval`` reports.
public enum ZoneRemoval: String, Sendable, Hashable, Codable {
    /// Deleted in the iOS settings (``CloudError/deletedByUser``). The mirror is
    /// already discarded; that is what the dialog promises.
    case byUser = "vomNutzer"
    /// Deleted by another device or program: the zone had been at the server once
    /// and is missing now (`zoneNotFound`), or the database reports it as deleted.
    /// The mirror stays; the zone is locked until the app decides.
    case fromRemote = "vonFern"
}

/// What has happened in a zone since a token: the answer of
/// `CKFetchRecordZoneChangesOperation`, without CloudKit types.
public struct Changes: Sendable {
    public var changed: [CloudRecord]
    public var deleted: [RecordName]
    /// The new token for the next pass; `nil` means: from scratch.
    public var marker: Data?

    public init(changed: [CloudRecord] = [], deleted: [RecordName] = [], marker: Data? = nil) {
        self.changed = changed
        self.deleted = deleted
        self.marker = marker
    }
}

/// Which zones of a database have changed since a token: the first step after
/// a silent push, before the zones themselves are asked.
public struct DatabaseChanges: Sendable {
    public var changed: [ZoneID]
    /// Deleted or, in the shared database, revoked.
    public var deleted: [ZoneID]
    /// The part of ``deleted`` that the human deleted themselves (iOS settings, see
    /// ``CloudError/deletedByUser``).
    public var deletedByUser: [ZoneID]
    public var marker: Data?

    public init(
        changed: [ZoneID] = [], deleted: [ZoneID] = [],
        deletedByUser: [ZoneID] = [], marker: Data? = nil
    ) {
        self.changed = changed
        self.deleted = deleted
        self.deletedByUser = deletedByUser
        self.marker = marker
    }
}

/// The result per record when saving with `ifServerRecordUnchanged`.
public enum StoreResult: Sendable {
    /// Accepted, with the server's new seal.
    case stored(CloudRecord)
    /// The server has a different version in the meantime; it comes along so the
    /// zone can merge and write again.
    case conflict(server: CloudRecord)
    /// The seal points to a record the server no longer has.
    case vanished
    /// The server rejects **only this record**, for example because its type or a
    /// field is missing in the production schema. The other records of the batch
    /// are saved.
    ///
    /// **Why no throw for the whole batch:** a new record type before the schema
    /// deployment would otherwise have dragged all other records of the same batch
    /// along, the zone would stand at "rejected", and the queue would hang on the
    /// same record at every pass. The ``ProfileZone`` takes such a record out of the
    /// queue and notes it (``ProfileZone/rejected``).
    case rejected(String)
}

/// A participant of a share: owner or invitee, with what CloudKit reveals about
/// them (name, if the address book knows them; otherwise nothing).
public struct Participant: Sendable, Hashable, Identifiable {
    public let identifier: String
    public let name: String?
    public let owner: Bool
    public let accepted: Bool
    /// Read and write: always with us; CloudKit could also allow read only.
    public let writing: Bool
    public var id: String { identifier }

    public init(identifier: String, name: String?, owner: Bool, accepted: Bool, writing: Bool = true) {
        self.identifier = identifier
        self.name = name
        self.owner = owner
        self.accepted = accepted
        self.writing = writing
    }
}

/// The share of a zone: the link to pass on and who reads along.
public struct Sharing: Sendable, Hashable {
    public let url: URL?
    public let participant: [Participant]

    public init(url: URL?, participant: [Participant]) {
        self.url = url
        self.participant = participant
    }

    /// The invitees without the owner.
    public var invited: [Participant] { participant.filter { !$0.owner } }
}

/// What a share link reveals about itself before it is accepted.
public struct SharingMetadata: Sendable, Hashable {
    public let url: URL
    public let zone: ZoneID
    public let ownerName: String?
    public let title: String?
    /// Whether this account has already accepted the share.
    public let accepted: Bool

    public init(url: URL, zone: ZoneID, ownerName: String?, title: String?, accepted: Bool) {
        self.url = url
        self.zone = zone
        self.ownerName = ownerName
        self.title = title
        self.accepted = accepted
    }
}

/// What a silent push means when it comes from CloudKit.
public enum PushInterpretation: Sendable, Hashable {
    /// A database has changed; `shared` says which.
    case database(shared: Bool)
}

/// The trip to the server: in operation ``CloudKitService``, in tests and with
/// `-attrappen` the ``CloudMock``. Everything that is CloudKit stands behind this
/// protocol; the ``ProfileZone`` and the ``CloudHub`` know no `CKRecord`.
///
/// Every method throws ``CloudError``; the zone decides on it whether it waits
/// (unreachable), stops (no account) or declares itself lost (zone missing).
public protocol CloudService: Sendable {

    /// The CloudKit environment this service talks to (`"Production"`,
    /// `"Development"`), `nil` if unknown (mock, or an app that does not specify
    /// it). See ``ProfileZone`` for the change of environment.
    var environment: String? { get }

    func accountStatus() async -> AccountStatus
    /// Reports when the account changes (`CKAccountChanged`): sign out, iCloud off
    /// for the app, sign in.
    func accountChanges() -> AsyncStream<Void>

    // MARK: Zones

    func createNew(_ zone: ZoneID) async throws(CloudError)
    func erase(_ zone: ZoneID) async throws(CloudError)
    /// The zones of a database: the own ones, or the accepted foreign ones.
    func zones(shared: Bool) async throws(CloudError) -> [ZoneID]
    func databaseChanges(
        shared: Bool, since marker: Data?
    ) async throws(CloudError)
        -> DatabaseChanges

    // MARK: Records

    func changes(_ zone: ZoneID, since marker: Data?) async throws(CloudError) -> Changes
    func fetchRecords(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) -> [CloudRecord]
    func persist(
        _ records: [CloudRecord], in zone: ZoneID
    ) async throws(CloudError)
        -> [StoreResult]
    func erase(_ names: [RecordName], in zone: ZoneID) async throws(CloudError)

    // MARK: The public database

    /// Puts a record into the **public** database: the mailbox for pairing two
    /// accounts.
    ///
    /// **Public means public.** Whoever knows the record name reads the content;
    /// there is no throttle and no sign-in in front. What goes in here must
    /// therefore be built **itself** so that knowing the name is the only hurdle and
    /// that hurdle high enough: a long, randomly generated name, a short deadline,
    /// and deleted as soon as it was collected.
    ///
    /// **Without zones of its own.** The public database knows only the default
    /// zone; therefore this path takes a ``RecordName`` and no ``ZoneID``.
    func createPublic(_ record: CloudRecord) async throws(CloudError)

    /// - Returns: `nil` if the record does not (or no longer) exist. **Not an
    ///   error:** a collected or expired mailbox is the normal case and no disruption.
    func readPublic(_ name: RecordName) async throws(CloudError) -> CloudRecord?

    func erasePublic(_ name: RecordName) async throws(CloudError)

    // MARK: Pushes

    /// The two database subscriptions for silent pushes, once per device.
    func subscribe() async throws(CloudError)
    func interpret(push: [AnyHashable: Any]) -> PushInterpretation?

    // MARK: Sharing

    /// Shares the zone (or reads the existing share) and returns the link.
    func share(_ zone: ZoneID, title: String) async throws(CloudError) -> Sharing
    /// The share of an own zone; `nil` if it is not shared.
    func sharing(_ zone: ZoneID) async throws(CloudError) -> Sharing?
    func remove(participant: String, from zone: ZoneID) async throws(CloudError)
    func endSharing(_ zone: ZoneID) async throws(CloudError)
    func sharingMetadata(_ url: URL) async throws(CloudError) -> SharingMetadata
    /// Accepts; afterwards the zone lies in this account's shared database.
    func accept(_ metadata: SharingMetadata) async throws(CloudError) -> ZoneID
    /// The participant leaves; the zone disappears from their shared database.
    func leave(_ zone: ZoneID) async throws(CloudError)
}

extension CloudService {
    /// Unknown until a service states it itself.
    public var environment: String? { nil }
}
