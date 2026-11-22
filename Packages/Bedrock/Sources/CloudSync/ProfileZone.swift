import Bedrock
import Foundation
import Observation

/// Where the zone of a profile currently stands, for the diagnostics line in the statistics sheet.
public enum ZoneState: Sendable, Hashable {
    /// No service attached (test, preview without cloud).
    case withoutCloud
    /// No iCloud account: everything stays local, the queue waits.
    case noAccount
    /// The zone has not been chosen yet; the directory is running (first launch).
    case unbound
    /// Bound, but no pass to the server yet.
    case neverSynced
    case synced(Date)
    /// The last pass failed on the network: the queue waits.
    case unreachable
    /// The zone no longer exists: share withdrawn or deleted by the owner.
    case lost
    /// The server refuses (schema, rights): nothing waits in vain, the report says why.
    case rejected(String)
}

/// One zone per profile, as a **mirror with a queue:** the packages above read
/// and write synchronously on the main actor. The mirror is up to date at once,
/// the change goes into the queue, and ``equalSince()`` carries it up as soon as
/// the server answers. What comes from there lands in the mirror and with the
/// observers per type.
///
/// **Why a mirror and not `async` all the way into the UI:** bookmarks, theme and
/// reading time used to live synchronously in `UserDefaults` and iCloud KVS; an
/// asynchronous carrier would have rebuilt every view. The mirror is also the
/// offline case: without network the app reads and writes as if nothing were
/// wrong ("unreachable" is a network state, not an error).
///
/// **Conflict:** writing uses the server's seal (`ifServerRecordUnchanged`). If
/// the server says "different in the meantime", the type's ``MergeRule`` merges
/// both versions, and the record goes up once more: at most four rounds per pass,
/// so a ping-pong of two devices does not drain the battery. Without a rule the
/// younger change wins.
///
/// **Token:** one change token (`CKServerChangeToken`) per zone, on disk next to
/// the mirror. After a restart the zone fetches only what has come since.
///
/// **Rejected individually** (``StoreResult/rejected(_:)``): if the server rejects
/// a record on its own because its type or a field is missing in the production
/// schema, the other records of the batch still go up. The one drops out of the
/// queue so it does not block every pass, stays in the mirror and is listed in
/// ``rejected``. It is retried on the next write of the same record, on the next
/// ``bind(to:)``, at every launch, and in an ordinary pass as soon as the server
/// brings news or ``retryInterval`` has passed since the last attempt. A schema
/// deployment thus heals it without a restart, and no pass hammers against the
/// same no twice.
///
/// A rejected record is a **pending write like any other:** if another version
/// comes from remote, the type's ``MergeRule`` applies; if a deletion comes, the
/// request wins. The rejection removes from the queue only the state that was
/// actually sent: whoever changes or deletes the record during the pass keeps
/// their change, and no note is left orphaned.
///
/// **Remote deletion** wins against the mirror, but not against a pending write:
/// whoever continued a session offline while the other device deleted the
/// statistics keeps it, since it was the newer intent.
///
/// **A vanished zone is not revived.** Until then a pass recreated a missing own
/// zone and wrote the whole mirror up, even after the human had chosen "Delete
/// Data" in the iOS settings, and also on every other device after one had
/// deleted the zone. The deletion was thus taken back on the next pass. Now:
///
/// * **Only what this device has never seen at the server is created anew:** the
///   first pass of a new profile. A zone that was there once and is now missing
///   was deleted by somebody: the zone is **locked** (``removed``,
///   ``ZoneState/lost``), no pass goes to the server any more, and ``onRemoval``
///   reports it.
/// * **Deleted by the user** (``CloudError/deletedByUser``) additionally discards
///   the mirror: the dialog promises that, and Apple requires it. **Deleted
///   remotely** leaves it in place: another device decided, and whether the data
///   stays here is the app's decision (``drop()``, ``unbind()``).
/// * **It continues only on explicit request:** ``drop()`` starts over, empty;
///   ``bind(to:)`` and ``unbind()`` also lift the lock.
///
/// **Why "seen once" and no note at the server:** whoever deletes an app's zones
/// deletes every note along with them, and a device that was offline would never
/// see it anyway; it gets only `zoneNotFound`. The one thing it knows for sure is
/// that it had the zone once.
@MainActor
@Observable
public final class ProfileZone {

    public private(set) var zone: ZoneID?
    public private(set) var state: ZoneState
    /// How many write and delete requests still have to go up.
    public private(set) var pending = 0
    /// The last successful pass to the server.
    public private(set) var recently: Date?
    /// Records the server rejected **individually** (``StoreResult/rejected(_:)``),
    /// with its reason, for the diagnostics line. Empty means: everything is up.
    public var rejected: [RecordName: String] { rejections.mapValues(\.reason) }
    /// Who shared the zone; only for a foreign zone; the hub sets it.
    public var sharedBy: String?
    /// Why the zone is locked, `nil` as long as it lives. See above, "A vanished zone
    /// is not revived".
    public private(set) var removed: ZoneRemoval?
    /// Reports that a zone has vanished that this device knew, **once**, after the
    /// pass that noticed it. The app decides here what happens to its own data;
    /// without a callback the zone stays locked and its state ``ZoneState/lost``.
    public var onRemoval: (@MainActor (ZoneRemoval) -> Void)?

    public let service: (any CloudService)?
    private let file: URL?
    private let unprompted: Bool
    private var records: [RecordName: CloudRecord] = [:]
    private var queue: [Request] = []
    private var marker: Data?
    private var rules: [String: MergeRule] = [:]
    private var observers: [UUID: (type: String, report: @MainActor ([CloudRecord]) -> Void)] = [:]
    private var rejections: [RecordName: Rejection] = [:]
    private var running = false
    private var repeatPass = false
    private var scheduled = false
    /// Whether the zone has ever been present at the server; only then does "missing" mean "deleted".
    private var confirmed = false
    /// After ``drop()``: the next missing zone may be created anew, even one deleted
    /// by the user.
    private var startedOver = false

    /// A request in the queue: at most one per record, the last one counts.
    enum Request: Codable, Hashable {
        case write(RecordName)
        case delete(RecordName)

        enum CodingKeys: String, CodingKey {
            case write = "schreiben"
            case delete = "loeschen"
        }

        var name: RecordName {
            switch self {
            case .write(let n), .delete(let n): n
            }
        }
    }

    /// A note from ``rejected``, with the time of the last attempt, on which the
    /// deadline ``retryInterval`` hangs.
    struct Rejection: Hashable {
        var reason: String
        var attempted: Date
    }

    /// What lies on disk: mirror, queue, token, zone.
    private struct Snapshot: Codable {
        var zone: ZoneID?
        var records: [CloudRecord]
        var queue: [Request]
        var marker: Data?
        var recently: Date?
        var sharedBy: String?
        /// Optional, so a mirror from before this field stays readable.
        var rejected: [RecordName: String]?
        /// The last attempt per note; if it is missing (older mirrors), the deadline counts as passed.
        var attemptedAt: [RecordName: Date]?
        /// Optional as above: an older mirror with a token counts as confirmed.
        var confirmed: Bool?
        var removed: ZoneRemoval?
        var startedOver: Bool?
        /// In which CloudKit environment this mirror came about, see ``restoreFromDisk()``.
        var environment: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case zone
            case records = "saetze"
            case queue = "schlange"
            case marker = "marke"
            case recently = "zuletzt"
            case sharedBy = "geteiltVon"
            case rejected = "abgelehnt"
            case attemptedAt = "abgelehntVersucht"
            case confirmed = "bestaetigt"
            case removed = "entfernt"
            case startedOver = "neuBegonnen"
            case environment = "umgebung"
        }
    }

    /// How many records go to the server in one pass. CloudKit takes 400; half
    /// leaves room for large bookmark identifiers.
    static let batch = 200

    /// Further passes when, after ``conflictRounds``, requests are still in the
    /// queue. One pass carries at most ``conflictRounds`` × ``batch`` records up; the
    /// first migration of old data can be more. Before, it said "synced" anyway while
    /// hundreds of records were still on their way. Now a new pass fetches fresh
    /// (which also resolves conflicts) and carries on; if even that is not enough,
    /// the old state stays, ``pending`` shows the rest, and the log says so.
    static let followUps = 3
    /// How often a conflict is rewritten per pass.
    static let conflictRounds = 4
    /// How long a rejected record rests before a pass without news tries it again.
    /// A schema deployment is not an event the server reports; an hour is quick
    /// enough for whoever just rolled it out, and rare enough not to keep the server
    /// busy with the same no.
    static let retryInterval: TimeInterval = 3600

    /// The time for note and deadline; set in tests.
    var clock: @MainActor () -> Date = { Date() }

    /// - Parameters:
    ///   - file: the mirror on disk (`profile/<id>/wolke.json`); `nil` keeps
    ///     everything in memory only (tests, preview).
    ///   - service: the trip to the server; `nil` means: no iCloud (``ZoneState/withoutCloud``).
    ///   - zone: the zone if the profile already has one; otherwise the hub binds.
    ///   - unprompted: whether every change triggers a pass on its own (in
    ///     operation); tests call ``equalSince()`` themselves so nothing runs on the side.
    public init(
        file: URL?, service: (any CloudService)?, zone: ZoneID? = nil, unprompted: Bool = true
    ) {
        self.file = file
        self.service = service
        self.unprompted = unprompted
        self.zone = zone
        self.state = service == nil ? .withoutCloud : (zone == nil ? .unbound : .neverSynced)
        restoreFromDisk()
        if let zone { self.zone = zone }
        pending = queue.count
    }

    // MARK: - Reading and writing (mirror)

    /// All records of a type, ordered by name.
    public func allRecords(ofType type: String) -> [CloudRecord] {
        records.values.filter { $0.type == type }.sorted { $0.name < $1.name }
    }

    public func record(type: String, name: String) -> CloudRecord? {
        records[RecordName(type: type, name: name)]
    }

    /// The types that occur in the mirror.
    public func types() -> Set<String> { Set(records.values.map(\.type)) }

    /// Writes into the mirror and enqueues. The server's seal and the creator stay
    /// on the record, `geaendert` is set now.
    public func write(_ record: CloudRecord, now: Date = Date()) {
        var new = record
        new.seal = records[record.id]?.seal
        new.creator = records[record.id]?.creator ?? record.creator
        new.changed = now
        records[record.id] = new
        enqueue(.write(record.id))
    }

    public func erase(type: String, name: String) {
        let identifier = RecordName(type: type, name: name)
        let known = records.removeValue(forKey: identifier) != nil
        rejections[identifier] = nil
        let waiting = queue.contains { $0.name == identifier }
        guard known || waiting else { return }
        enqueue(.delete(identifier))
    }

    public func eraseAll(type: String) {
        for record in allRecords(ofType: type) { erase(type: type, name: record.name) }
    }

    /// The rule for a type; without a rule the younger change wins.
    public func rule(for type: String, _ rule: MergeRule) {
        rules[type] = rule
    }

    /// Reports when records of this type came from remote, with the whole state of
    /// the type. The return value holds the observation; when it is dropped, the
    /// observation ends.
    public func observe(
        _ type: String, _ report: @escaping @MainActor ([CloudRecord]) -> Void
    ) -> ObservationToken {
        let identifier = UUID()
        observers[identifier] = (type, report)
        return ObservationToken { [weak self] in self?.observers[identifier] = nil }
    }

    // MARK: - Binding

    /// Binds the zone: the first time (own or found zone) or after an accepted
    /// share. The token drops so the next pass fetches everything; what the mirror
    /// already has goes up as a write request and merges there with what lies there.
    public func bind(to zone: ZoneID) {
        guard self.zone != zone || removed != nil else { return }
        self.zone = zone
        removed = nil
        confirmed = false
        startedOver = false
        marker = nil
        for record in records.values {
            var without = record
            without.seal = nil
            records[record.id] = without
            if !queue.contains(where: { $0.name == record.id }) { queue.append(.write(record.id)) }
        }
        pending = queue.count
        state = .neverSynced
        persist()
        kick()
    }

    /// Takes all records of a type out of the mirror **without** a delete request:
    /// nothing goes to the server, the records are merely forgotten. For taking over
    /// a share: before the mirror binds to the owner's zone, its own
    /// `Profileinstellung` records (name, color, theme) drop, so the owner's apply
    /// there. An ``erase(type:name:)`` would delete them at the owner after binding,
    /// and leaving them would play them against theirs.
    public func discard(type: String) {
        let names = records.values.filter { $0.type == type }.map(\.id)
        guard !names.isEmpty || queue.contains(where: { $0.name.type == type }) else { return }
        for name in names { records[name] = nil }
        queue.removeAll { $0.name.type == type }
        rejections = rejections.filter { $0.key.type != type }
        pending = queue.count
        persist()
    }

    /// Detaches the zone from the mirror: "Remove from iCloud". The records stay,
    /// their seals and the token drop; on the next binding it is a new zone.
    public func unbind() {
        zone = nil
        marker = nil
        for record in records.values {
            var without = record
            without.seal = nil
            records[record.id] = without
        }
        queue.removeAll()
        rejections = [:]
        pending = 0
        recently = nil
        removed = nil
        confirmed = false
        startedOver = false
        state = service == nil ? .withoutCloud : .unbound
        persist()
    }

    /// **Starts over, empty:** the explicit wish after a removal (``onRemoval``) or
    /// after "Delete all iCloud data" in the app.
    ///
    /// Mirror, queue, token and notes drop, the lock too; the binding stays. The next
    /// pass may create the zone anew, even one deleted by the user, and carries up
    /// only what was written **afterwards**. Whoever observes is told the empty state
    /// of their type.
    public func drop() {
        let types = Set(records.values.map(\.type))
        clearMirror()
        removed = nil
        confirmed = false
        startedOver = true
        state = service == nil ? .withoutCloud : (zone == nil ? .unbound : .neverSynced)
        persist()
        report(types)
    }

    /// The hub learned from the database changes that an **own** zone has been
    /// deleted: the same rule as in the pass. Only one this device already knew, and
    /// not one it has just started anew itself.
    public func noteRemoved(_ reason: ZoneRemoval) {
        guard removed == nil, let zone else { return }
        guard reason == .byUser ? !startedOver : (confirmed && !startedOver) else { return }
        lockZone(reason, zone)
        onRemoval?(reason)
    }

    /// Locks the zone, see above. Deleted by the user also means: the mirror is gone.
    private func lockZone(_ reason: ZoneRemoval, _ zone: ZoneID) {
        removed = reason
        state = .lost
        let types = Set(records.values.map(\.type))
        if reason == .byUser { clearMirror() }
        Diagnostics.step(
            reason == .byUser
                ? "Cloud \(zone.name): deleted in iOS settings — mirror discarded, nothing is recreated"
                : "Cloud \(zone.name): deleted remotely — blocked, nothing is recreated",
            since: nil, area: "Cloud")
        persist()
        if reason == .byUser { report(types) }
    }

    private func clearMirror() {
        records = [:]
        queue = []
        rejections = [:]
        marker = nil
        recently = nil
        pending = 0
    }

    /// The hub learned that the zone no longer exists.
    public func noteLost() {
        state = .lost
        persist()
    }

    // MARK: - The pass to the server

    /// Fetches what happened remotely and carries the queue up. If one is already
    /// running, it remembers that it must run once more.
    public func equalSince() async {
        guard let service, let zone, removed == nil else { return }
        if running {
            repeatPass = true
            return
        }
        running = true
        defer { running = false }
        var followUps = 0
        var noticed: ZoneRemoval?
        repeat {
            repeatPass = false
            let status = await service.accountStatus()
            guard status == .available else {
                state = .noAccount
                persist()
                return
            }
            do throws(CloudError) {
                let news = try await fetch(service, zone)
                requeueRejected(news: news)
                try await push(service, zone)
                if queue.isEmpty {
                    let now = Date()
                    recently = now
                    state = .synced(now)
                } else if followUps < ProfileZone.followUps {
                    followUps += 1
                    repeatPass = true
                } else {
                    Diagnostics.deficiency(
                        "Cloud \(zone.name): \(queue.count) jobs waiting after \(followUps + 1) passes",
                        since: nil, area: "Cloud")
                }
            } catch {
                // **Deleted by the user in the middle of the pass** (between fetching and
                // pushing): the same rule as in ``fetch(_:_:)``.
                if error == .deletedByUser, removed == nil, !startedOver {
                    lockZone(.byUser, zone)
                }
                if let reason = removed {
                    noticed = reason
                    break
                }
                switch error {
                case .noAccount: state = .noAccount
                case .zoneMissing, .deletedByUser: state = .lost
                case .rejected(let reason): state = .rejected(reason)
                case .unreachable, .miscellaneous: state = .unreachable
                }
                Diagnostics.deficiency("Cloud \(zone.name): \(error)", since: nil, area: "Cloud")
            }
            persist()
        } while repeatPass
        if let noticed { onRemoval?(noticed) }
    }

    /// - Returns: whether the server had anything new.
    private func fetch(_ service: any CloudService, _ zone: ZoneID) async throws(CloudError) -> Bool {
        let changes: Changes
        do throws(CloudError) {
            changes = try await service.changes(zone, since: marker)
        } catch .zoneMissing where !zone.shared {
            // **The own zone is missing.** If this device knew it, somebody deleted it:
            // lock instead of reviving. Otherwise it is the first pass: create it, with
            // everything the mirror has.
            if confirmed, !startedOver {
                lockZone(.fromRemote, zone)
                throw .zoneMissing
            }
            try await recreate(service, zone)
            return false
        } catch .deletedByUser where startedOver && !zone.shared {
            // deliberately silent: after ``drop()`` explicitly wanted, new and empty; the
            // deletion itself was already in the log when locking.
            try await recreate(service, zone)
            return false
        } catch .deletedByUser {
            lockZone(.byUser, zone)
            throw .deletedByUser
        }
        confirmed = true
        startedOver = false
        adopt(changes)
        return !changes.changed.isEmpty || !changes.deleted.isEmpty
    }

    /// Creates the own zone and enqueues the whole mirror as write requests.
    private func recreate(_ service: any CloudService, _ zone: ZoneID) async throws(CloudError) {
        try await service.createNew(zone)
        confirmed = true
        startedOver = false
        marker = nil
        for record in records.values {
            var without = record
            without.seal = nil
            records[record.id] = without
            if !queue.contains(where: { $0.name == record.id }) { queue.append(.write(record.id)) }
        }
    }

    /// Re-enqueues the rejected records that are due: all of them if the server had
    /// news, otherwise those whose last attempt is ``retryInterval`` ago. Once per
    /// pass: if they fail again, `push` takes them out, and only the next pass asks
    /// again.
    private func requeueRejected(news: Bool) {
        let now = clock()
        let due = rejections.filter { name, rejection in
            records[name] != nil && !queue.contains { $0.name == name }
                && (news || now.timeIntervalSince(rejection.attempted) >= ProfileZone.retryInterval)
        }
        guard !due.isEmpty else { return }
        for name in due.keys.sorted(by: { ($0.type, $0.name) < ($1.type, $1.name) }) {
            queue.append(.write(name))
        }
        pending = queue.count
    }

    /// Foreign changes into the mirror, with regard to the queue: a record whose
    /// deletion is still waiting does not come back (after our own save the server
    /// returns our own records as a change, an echo that would otherwise undo a
    /// deletion). A rejected record counts as a pending write and is re-enqueued
    /// in the process.
    func adopt(_ changes: Changes) {
        var affected: Set<String> = []
        for fremd in changes.changed {
            if queue.contains(.delete(fremd.id)) { continue }
            if isPending(fremd.id), let own = records[fremd.id] {
                var merged = rule(fremd.type).merge(own, fremd)
                merged.seal = fremd.seal
                records[fremd.id] = merged
                requeue(fremd.id)
            } else {
                records[fremd.id] = fremd
                rejections[fremd.id] = nil
            }
            affected.insert(fremd.type)
        }
        for name in changes.deleted {
            if isPending(name), records[name] != nil {
                records[name]?.seal = nil
                requeue(name)
                continue
            }
            rejections[name] = nil
            if records.removeValue(forKey: name) != nil { affected.insert(name.type) }
        }
        marker = changes.marker
        pending = queue.count
        report(affected)
    }

    private func isPending(_ name: RecordName) -> Bool {
        queue.contains(.write(name)) || rejections[name] != nil
    }

    private func requeue(_ name: RecordName) {
        if !queue.contains(.write(name)) { queue.append(.write(name)) }
    }

    private func push(_ service: any CloudService, _ zone: ZoneID) async throws(CloudError) {
        var round = 0
        while !queue.isEmpty, round < ProfileZone.conflictRounds {
            round += 1
            let deletions = queue.compactMap { request -> RecordName? in
                if case .delete(let n) = request { return n }
                return nil
            }
            if !deletions.isEmpty {
                try await service.erase(Array(deletions.prefix(ProfileZone.batch)), in: zone)
                let finished = Set(deletions.prefix(ProfileZone.batch))
                queue.removeAll { finished.contains($0.name) }
                pending = queue.count
                persist()
            }
            let writes = queue.compactMap { request -> CloudRecord? in
                if case .write(let n) = request { return records[n] }
                return nil
            }
            guard !writes.isEmpty else {
                queue.removeAll { records[$0.name] == nil && !$0.isDelete }
                pending = queue.count
                continue
            }
            let batch = Array(writes.prefix(ProfileZone.batch))
            let results = try await service.persist(batch, in: zone)
            var affected: Set<String> = []
            for (sent, result) in zip(batch, results) {
                switch result {
                case .stored(let new):
                    rejections[sent.id] = nil
                    guard let current = records[sent.id] else { continue }
                    // **Seal and server time belong together.** Both are statements by the server
                    // *about* the record and not payload; whoever takes over only the seal has a
                    // record that lies at the server and still carries no stamp, and
                    // ``CloudRecord/serverTime`` would come only on the next read. For a deadline
                    // that hangs on it, that would mean it starts running only on the pass after
                    // next.
                    if current.changed == sent.changed {
                        var done = current
                        done.seal = new.seal
                        done.serverTime = new.serverTime
                        records[sent.id] = done
                        queue.removeAll { $0 == .write(sent.id) }
                    } else {
                        records[sent.id]?.seal = new.seal
                        records[sent.id]?.serverTime = new.serverTime
                    }
                case .conflict(let server):
                    guard let own = records[sent.id] else { continue }
                    var merged = rule(server.type).merge(own, server)
                    merged.seal = server.seal
                    merged.changed = max(merged.changed, own.changed)
                    records[sent.id] = merged
                    affected.insert(server.type)
                case .vanished:
                    records[sent.id]?.seal = nil
                case .rejected(let reason):
                    guard let current = records[sent.id], current.changed == sent.changed else {
                        continue
                    }
                    queue.removeAll { $0 == .write(sent.id) }
                    if rejections[sent.id] == nil {
                        Diagnostics.deficiency(
                            "Cloud \(zone.name): \(sent.type)/\(sent.name) rejected — \(reason)",
                            since: nil, area: "Cloud")
                    }
                    rejections[sent.id] = Rejection(reason: reason, attempted: clock())
                }
            }
            pending = queue.count
            persist()
            report(affected)
        }
    }

    private func rule(_ type: String) -> MergeRule { rules[type] ?? .younger }

    private func report(_ types: Set<String>) {
        guard !types.isEmpty else { return }
        for (_, entry) in observers where types.contains(entry.type) {
            entry.report(allRecords(ofType: entry.type))
        }
    }

    private func enqueue(_ request: Request) {
        queue.removeAll { $0.name == request.name }
        queue.append(request)
        pending = queue.count
        persist()
        kick()
    }

    /// One pass, bundled: whoever reorders ten bookmarks triggers one, not ten.
    private func kick() {
        guard unprompted, service != nil, zone != nil, removed == nil, !scheduled else { return }
        scheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.scheduled = false
            await self.equalSince()
        }
    }

    // MARK: - Disk

    private func restoreFromDisk() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else { return }
        zone = snapshot.zone ?? zone
        records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        queue = snapshot.queue
        marker = snapshot.marker
        recently = snapshot.recently
        sharedBy = snapshot.sharedBy
        confirmed = snapshot.confirmed ?? (snapshot.marker != nil || snapshot.recently != nil)
        removed = snapshot.removed
        startedOver = snapshot.startedOver ?? false
        let attempted = snapshot.attemptedAt ?? [:]
        rejections = (snapshot.rejected ?? [:]).filter { records[$0.key] != nil }.reduce(into: [:]) {
            $0[$1.key] = Rejection(reason: $1.value, attempted: attempted[$1.key] ?? .distantPast)
        }
        // Every launch tries the rejected records once; a schema deployment in between
        // heals them this way without anybody touching them. If they fail again, the
        // pass takes them out of the queue again.
        for name in rejections.keys.sorted(by: { ($0.type, $0.name) < ($1.type, $1.name) })
        where records[name] != nil && !queue.contains(where: { $0.name == name }) {
            queue.append(.write(name))
        }
        if let here = service?.environment, snapshot.environment != here, zone != nil {
            startInNewEnvironment(here, previously: snapshot.environment)
        }
        if service != nil, zone != nil { state = recently.map(ZoneState.synced) ?? .neverSynced }
        if service != nil, removed != nil { state = .lost }
    }

    /// A mirror from a **different CloudKit environment**: first contact instead of lock.
    ///
    /// **The finding:** the television ran as a debug build against "Development",
    /// the phone from TestFlight against "Production": two separate worlds with
    /// separate data, even with the same Apple ID. If a device changes environment,
    /// the zone is missing there although the mirror had confirmed it; that would mean
    /// "deleted remotely", and the caller cleared the profile off the device. But the
    /// zone of the other environment is not deleted, it is just not here. So:
    /// everything up anew, delete nothing. A mirror without the statement (from before
    /// this guard) counts as foreign; a first contact never deletes anything, only the
    /// lock is destructive.
    private func startInNewEnvironment(_ here: String, previously: String?) {
        marker = nil
        recently = nil
        confirmed = false
        startedOver = false
        removed = nil
        rejections = [:]
        for record in records.values {
            var without = record
            without.seal = nil
            records[record.id] = without
            if !queue.contains(where: { $0.name == record.id }) { queue.append(.write(record.id)) }
        }
        pending = queue.count
        Diagnostics.step(
            "Cloud \(zone?.name ?? "?"): mirror from \(previously ?? "unknown environment") — restarted in \(here)",
            since: nil, area: "Cloud")
        persist()
    }

    private func persist() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = Snapshot(
            zone: zone, records: Array(records.values), queue: queue, marker: marker, recently: recently,
            sharedBy: sharedBy, rejected: rejected.isEmpty ? nil : rejected,
            attemptedAt: rejections.isEmpty ? nil : rejections.mapValues(\.attempted),
            confirmed: confirmed, removed: removed, startedOver: startedOver ? true : nil,
            environment: service?.environment)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension ProfileZone.Request {
    var isDelete: Bool {
        if case .delete = self { return true }
        return false
    }
}

/// Holds an observation; when it is dropped, the observation ends.
public final class ObservationToken: Sendable {
    private let end: @Sendable () -> Void

    init(end: @escaping @MainActor () -> Void) {
        self.end = { Task { @MainActor in end() } }
    }

    deinit { end() }
}
