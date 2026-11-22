import Foundation

/// A CloudKit in memory: **one server, several accounts.** ``access(_:)`` hands
/// out a ``CloudService`` per Apple ID, and what one account shares, the other
/// sees in its shared database. That makes it possible on a computer to test
/// what otherwise needs two devices and two Apple IDs: zones, tokens, conflicts
/// via the seal, sharing, accepting, withdrawing, leaving.
///
/// The same mock runs in the simulator with `-attrappen`; there everything stays
/// in the process and no account is touched.
///
/// **What it reproduces and what not:** change tokens are sequence numbers of a
/// journal, seals are version numbers; saving with an old seal returns the
/// conflict with the server version, as CloudKit does. What is missing: quotas,
/// sizes, rates, the delay of a push. For that there are ``reachable``,
/// ``setAccount(_:_:)`` and ``deny(type:reason:)`` (a record type is missing in
/// the schema) as levers a test flips.
public final class CloudMock: @unchecked Sendable {

    /// Whether the "server" answers; `false` means every pass throws `unreachable`.
    public var reachable: Bool {
        get { lock.withLock { _reachable } }
        set { lock.withLock { _reachable = newValue } }
    }

    /// The "server's" clock, **settable, and that is its purpose.**
    ///
    /// ``CloudRecord/serverTime`` is the anchor of every deadline; a test for it must
    /// be able to fast-forward without touching the computer's clock. `nil` means:
    /// ordinary time.
    public var clock: Date? {
        get { lock.withLock { _clock } }
        set { lock.withLock { _clock = newValue } }
    }

    /// Simulates that a record type is missing in the production schema: every
    /// record of this type comes back from saving as ``StoreResult/rejected(_:)``,
    /// and the other records of the same batch are saved, just as ``CloudKitService``
    /// passes on an `invalidArguments` per record. A second call with `nil` as the
    /// reason is the schema deployment: the type is accepted again.
    public func deny(type: String, reason: String? = "Cannot create new type in production schema") {
        lock.withLock { _denied[type] = reason }
    }

    /// Simulates "Delete data" in the iOS settings (`CKError.userDeletedZone`): the
    /// zone is gone, and every access by the owner throws
    /// ``CloudError/deletedByUser`` instead of ``CloudError/zoneMissing``, until they
    /// create it anew. The database changes report it as deleted **and** deleted by
    /// the user.
    public func eraseByUser(_ zone: ZoneID, user: String) {
        lock.withLock {
            let resolved = ZoneID(name: zone.name, owner: user)
            guard zones[resolved] != nil else { return }
            noteZone(resolved, deleted: true, byUser: true)
            zones[resolved] = nil
            _userDeleted.insert(resolved)
        }
    }

    private let lock = NSLock()
    private var _userDeleted: Set<ZoneID> = []
    private var _denied: [String: String] = [:]
    private var _reachable = true
    private var _clock: Date?
    private var accounts: [String: AccountStatus] = [:]
    private var zones: [ZoneID: Zone] = [:]
    private var journals: [JournalKey: [JournalEntry]] = [:]
    private var sequence = 0
    private var accountWakers: [String: [@Sendable () -> Void]] = [:]
    /// The public database: **one for all accounts,** because that is exactly what it is.
    private var mailbox: [RecordName: CloudRecord] = [:]

    /// A zone with its journal; the owner is in the identifier.
    private struct Zone {
        var records: [RecordName: (record: CloudRecord, version: Int)] = [:]
        var journal: [(number: Int, name: RecordName, deleted: Bool)] = []
        var sharing: (url: URL, participant: [String: Participant])?
    }

    private struct JournalKey: Hashable {
        let user: String
        let shared: Bool
    }

    private struct JournalEntry {
        let number: Int
        let zone: ZoneID
        let deleted: Bool
        var byUser = false
    }

    public init() {}

    /// The service of an account: `user` is the record name of the Apple ID
    /// (`_abc…` in CloudKit; here a name such as "alex").
    /// - Parameter environment: the CloudKit environment this access reports
    ///   (``CloudService/environment``), for tests of the environment guard.
    public func access(_ user: String, name: String? = nil, environment: String? = nil) -> Access {
        lock.withLock { if accounts[user] == nil { accounts[user] = .available } }
        return Access(server: self, user: user, name: name ?? user, environment: environment)
    }

    /// Sets the account status of a user and wakes whoever listens to `CKAccountChanged`.
    public func setAccount(_ user: String, _ status: AccountStatus) {
        let wakers = lock.withLock {
            accounts[user] = status
            return accountWakers[user] ?? []
        }
        for w in wakers { w() }
    }

    /// Everything that lies in a zone, for tests that look into the server's belly.
    public func content(_ zone: ZoneID) -> [CloudRecord] {
        lock.withLock { zones[zone]?.records.values.map(\.record).sorted { $0.name < $1.name } ?? [] }
    }

    public func zoneList() -> [ZoneID] { lock.withLock { Array(zones.keys) } }

    // MARK: - Inside (under the lock)

    /// `withLock` throws untyped; here the ``CloudError`` stays typed.
    fileprivate func locked<T>(_ torso: () throws(CloudError) -> T) throws(CloudError) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try torso()
    }

    private func next() -> Int {
        sequence += 1
        return sequence
    }

    private func seal(_ version: Int) -> Data { Data(String(version).utf8) }
    private func version(_ seal: Data?) -> Int? {
        seal.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
    }
    private func marker(_ number: Int) -> Data { Data(String(number).utf8) }
    private func number(_ marker: Data?) -> Int {
        marker.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    }

    /// The zone as `user` sees it: their own, or a foreign one they take part in.
    private func resolvedZone(_ zone: ZoneID, for user: String) -> ZoneID? {
        guard let owner = zone.owner else {
            return zones[ZoneID(name: zone.name, owner: user)] != nil
                ? ZoneID(name: zone.name, owner: user) : nil
        }
        let resolved = ZoneID(name: zone.name, owner: owner)
        guard let z = zones[resolved], z.sharing?.participant[user]?.accepted == true else { return nil }
        return resolved
    }

    /// Why `user` does not (any longer) see this zone: deleted by the user or simply not there.
    fileprivate func missing(_ zone: ZoneID, for user: String) -> CloudError {
        let own = ZoneID(name: zone.name, owner: zone.owner ?? user)
        return _userDeleted.contains(own) ? .deletedByUser : .zoneMissing
    }

    /// Enters a zone change into the database journals of everyone who sees it.
    private func noteZone(
        _ zone: ZoneID, deleted: Bool, byUser: Bool = false, onlyFor user: String? = nil
    ) {
        guard let owner = zone.owner else { return }
        let n = next()
        if let user {
            journals[JournalKey(user: user, shared: true), default: []].append(
                JournalEntry(number: n, zone: zone, deleted: deleted))
            return
        }
        journals[JournalKey(user: owner, shared: false), default: []].append(
            JournalEntry(
                number: n, zone: ZoneID(name: zone.name), deleted: deleted,
                byUser: byUser))
        for (participant, entry) in zones[zone]?.sharing?.participant ?? [:] where entry.accepted {
            journals[JournalKey(user: participant, shared: true), default: []].append(
                JournalEntry(number: n, zone: zone, deleted: deleted))
        }
    }

    // MARK: - The access of an account

    public struct Access: CloudService {
        let server: CloudMock
        public let user: String
        public let name: String
        public let environment: String?

        /// When a push is meant "for this account": `["attrappe-geteilt": Bool]`.
        public func interpret(push: [AnyHashable: Any]) -> PushInterpretation? {
            guard let shared = push["attrappe-geteilt"] as? Bool else { return nil }
            return .database(shared: shared)
        }

        public func accountStatus() async -> AccountStatus {
            server.lock.withLock { server.accounts[user] ?? .noAccount }
        }

        public func accountChanges() -> AsyncStream<Void> {
            AsyncStream { continuation in
                server.lock.withLock {
                    server.accountWakers[user, default: []].append { continuation.yield() }
                }
            }
        }

        private func check() throws(CloudError) {
            let (reachable, status) = server.lock.withLock { (server._reachable, server.accounts[user]) }
            guard reachable else { throw .unreachable }
            guard status == .available else { throw .noAccount }
        }

        public func createNew(_ zone: ZoneID) async throws(CloudError) {
            try check()
            server.lock.withLock {
                let resolved = ZoneID(name: zone.name, owner: user)
                guard server.zones[resolved] == nil else { return }
                server._userDeleted.remove(resolved)
                server.zones[resolved] = Zone()
                server.noteZone(resolved, deleted: false)
            }
        }

        public func erase(_ zone: ZoneID) async throws(CloudError) {
            try check()
            server.lock.withLock {
                let resolved = ZoneID(name: zone.name, owner: user)
                guard server.zones[resolved] != nil else { return }
                server.noteZone(resolved, deleted: true)
                server.zones[resolved] = nil
            }
        }

        public func zones(shared: Bool) async throws(CloudError) -> [ZoneID] {
            try check()
            return server.lock.withLock {
                server.zones.compactMap { identifier, zone in
                    if !shared {
                        return identifier.owner == user ? ZoneID(name: identifier.name) : nil
                    }
                    return identifier.owner != user && zone.sharing?.participant[user]?.accepted == true
                        ? identifier : nil
                }
                .sorted { $0.name < $1.name }
            }
        }

        public func databaseChanges(
            shared: Bool, since marker: Data?
        ) async throws(CloudError)
            -> DatabaseChanges
        {
            try check()
            return server.lock.withLock {
                let since = server.number(marker)
                let entries = (server.journals[JournalKey(user: user, shared: shared)] ?? [])
                    .filter { $0.number > since }
                var state: [ZoneID: Bool] = [:]
                var byUser: Set<ZoneID> = []
                for e in entries {
                    state[e.zone] = e.deleted
                    if e.byUser { byUser.insert(e.zone) } else { byUser.remove(e.zone) }
                }
                let deleted = state.filter(\.value).map(\.key).sorted { $0.name < $1.name }
                return DatabaseChanges(
                    changed: state.filter { !$0.value }.map(\.key).sorted { $0.name < $1.name },
                    deleted: deleted,
                    deletedByUser: deleted.filter(byUser.contains),
                    marker: server.marker(server.sequence))
            }
        }

        public func changes(
            _ zone: ZoneID, since marker: Data?
        ) async throws(CloudError)
            -> Changes
        {
            try check()
            return try server.locked { () throws(CloudError) -> Changes in
                guard let resolved = server.resolvedZone(zone, for: user), let z = server.zones[resolved]
                else {
                    throw server.missing(zone, for: user)
                }
                let since = server.number(marker)
                var state: [RecordName: Bool] = [:]
                for e in z.journal where e.number > since { state[e.name] = e.deleted }
                let changed = state.filter { !$0.value }.keys.compactMap { name -> CloudRecord? in
                    guard let (record, version) = z.records[name] else { return nil }
                    var s = record
                    s.seal = server.seal(version)
                    return s
                }
                return Changes(
                    changed: changed.sorted { $0.name < $1.name },
                    deleted: state.filter(\.value).map(\.key).sorted { $0.name < $1.name },
                    marker: server.marker(server.sequence))
            }
        }

        public func fetchRecords(
            _ names: [RecordName], in zone: ZoneID
        ) async throws(CloudError)
            -> [CloudRecord]
        {
            try check()
            return try server.locked { () throws(CloudError) -> [CloudRecord] in
                guard let resolved = server.resolvedZone(zone, for: user), let z = server.zones[resolved]
                else {
                    throw server.missing(zone, for: user)
                }
                return names.compactMap { name in
                    guard let (record, version) = z.records[name] else { return nil }
                    var s = record
                    s.seal = server.seal(version)
                    return s
                }
            }
        }

        public func persist(
            _ records: [CloudRecord], in zone: ZoneID
        ) async throws(CloudError)
            -> [StoreResult]
        {
            try check()
            return try server.locked { () throws(CloudError) -> [StoreResult] in
                guard let resolved = server.resolvedZone(zone, for: user), var z = server.zones[resolved]
                else {
                    throw server.missing(zone, for: user)
                }
                var results: [StoreResult] = []
                for record in records {
                    if let reason = server._denied[record.type] {
                        results.append(.rejected(reason))
                        continue
                    }
                    let existingEntry = z.records[record.id]
                    let brought = server.version(record.seal)
                    if let existingEntry, existingEntry.version != brought {
                        var s = existingEntry.record
                        s.seal = server.seal(existingEntry.version)
                        results.append(.conflict(server: s))
                        continue
                    }
                    if existingEntry == nil, brought != nil {
                        results.append(.vanished)
                        continue
                    }
                    let version = (existingEntry?.version ?? 0) + 1
                    var new = record
                    new.seal = nil
                    new.creator = existingEntry?.record.creator ?? user
                    // **The server stamps, not the writer.** Exactly this difference is the point
                    // of ``CloudRecord/serverTime``.
                    new.serverTime = server._clock ?? Date()
                    z.records[record.id] = (new, version)
                    z.journal.append((server.next(), record.id, false))
                    new.seal = server.seal(version)
                    results.append(.stored(new))
                }
                server.zones[resolved] = z
                server.noteZone(resolved, deleted: false)
                return results
            }
        }

        public func erase(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) {
            try check()
            try server.locked { () throws(CloudError) in
                guard let resolved = server.resolvedZone(zone, for: user), var z = server.zones[resolved]
                else {
                    throw server.missing(zone, for: user)
                }
                for name in names where z.records[name] != nil {
                    z.records[name] = nil
                    z.journal.append((server.next(), name, true))
                }
                server.zones[resolved] = z
                server.noteZone(resolved, deleted: false)
            }
        }

        public func subscribe() async throws(CloudError) { try check() }

        // MARK: The public database

        /// **Without account separation, and that is no simplification.** The public
        /// database is the same for every account; whoever knows the record name reads
        /// it. A mock that separated here would let a test go green that fails on the
        /// device, or worse: it would conceal that a stranger can read along.
        public func createPublic(_ record: CloudRecord) async throws(CloudError) {
            try check()
            try server.locked { server.mailbox[record.id] = record }
        }

        public func readPublic(
            _ name: RecordName
        ) async throws(CloudError)
            -> CloudRecord?
        {
            try check()
            return try server.locked { server.mailbox[name] }
        }

        public func erasePublic(_ name: RecordName) async throws(CloudError) {
            try check()
            try server.locked { server.mailbox[name] = nil }
        }

        // MARK: Sharing

        public func share(_ zone: ZoneID, title: String) async throws(CloudError) -> Sharing {
            try check()
            return try server.locked { () throws(CloudError) -> Sharing in
                let resolved = ZoneID(name: zone.name, owner: user)
                guard var z = server.zones[resolved] else { throw .zoneMissing }
                if z.sharing == nil {
                    z.sharing = (
                        URL(string: "https://www.icloud.com/share/attrappe-\(user)-\(zone.name)")!,
                        [user: Participant(identifier: user, name: name, owner: true, accepted: true)]
                    )
                    server.zones[resolved] = z
                }
                return Sharing(url: z.sharing?.url, participant: participantList(z))
            }
        }

        private func participantList(_ z: Zone) -> [Participant] {
            (z.sharing?.participant.values ?? [:].values).sorted {
                ($0.owner ? 0 : 1, $0.identifier) < ($1.owner ? 0 : 1, $1.identifier)
            }
        }

        public func sharing(_ zone: ZoneID) async throws(CloudError) -> Sharing? {
            try check()
            return try server.locked { () throws(CloudError) -> Sharing? in
                let resolved = ZoneID(name: zone.name, owner: user)
                guard let z = server.zones[resolved] else { throw .zoneMissing }
                guard let f = z.sharing else { return nil }
                return Sharing(url: f.url, participant: participantList(z))
            }
        }

        public func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
            try check()
            server.lock.withLock {
                let resolved = ZoneID(name: zone.name, owner: user)
                guard var z = server.zones[resolved], z.sharing?.participant[participant] != nil else {
                    return
                }
                z.sharing?.participant[participant] = nil
                server.zones[resolved] = z
                server.noteZone(resolved, deleted: true, onlyFor: participant)
            }
        }

        public func endSharing(_ zone: ZoneID) async throws(CloudError) {
            try check()
            server.lock.withLock {
                let resolved = ZoneID(name: zone.name, owner: user)
                guard var z = server.zones[resolved], let f = z.sharing else { return }
                for t in f.participant.keys where t != user {
                    server.noteZone(resolved, deleted: true, onlyFor: t)
                }
                z.sharing = nil
                server.zones[resolved] = z
            }
        }

        public func sharingMetadata(_ url: URL) async throws(CloudError) -> SharingMetadata {
            try check()
            return try server.locked { () throws(CloudError) -> SharingMetadata in
                guard let (identifier, z) = server.zones.first(where: { $0.value.sharing?.url == url }) else {
                    throw .rejected("Unknown share link")
                }
                // **Like CloudKit at the owner:** when the owner opens their own share, the
                // owner is called `__defaultOwner__`; ``ZoneID`` turns that into the own zone.
                let zone =
                    identifier.owner == user
                    ? ZoneID(name: identifier.name, owner: ZoneID.ownAccount) : identifier
                return SharingMetadata(
                    url: url, zone: zone,
                    ownerName: z.sharing?.participant[identifier.owner ?? ""]?.name,
                    title: nil, accepted: z.sharing?.participant[user]?.accepted == true)
            }
        }

        public func accept(_ metadata: SharingMetadata) async throws(CloudError) -> ZoneID {
            try check()
            return try server.locked { () throws(CloudError) -> ZoneID in
                // **The own share yields the own zone.** CloudKit does not even accept it, it
                // is already there (same Apple ID on two devices).
                if metadata.zone.owner == nil || metadata.zone.owner == user {
                    guard server.zones[ZoneID(name: metadata.zone.name, owner: user)] != nil
                    else { throw .zoneMissing }
                    return ZoneID(name: metadata.zone.name)
                }
                guard var z = server.zones[metadata.zone], z.sharing != nil else { throw .zoneMissing }
                z.sharing?.participant[user] = Participant(
                    identifier: user, name: name, owner: false, accepted: true)
                server.zones[metadata.zone] = z
                server.noteZone(metadata.zone, deleted: false, onlyFor: user)
                return metadata.zone
            }
        }

        public func leave(_ zone: ZoneID) async throws(CloudError) {
            try check()
            server.lock.withLock {
                guard var z = server.zones[zone] else { return }
                z.sharing?.participant[user] = nil
                server.zones[zone] = z
                server.noteZone(zone, deleted: true, onlyFor: user)
            }
        }
    }
}
