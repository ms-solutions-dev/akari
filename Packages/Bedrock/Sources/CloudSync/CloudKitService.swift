import CloudKit
import Foundation

/// The ``CloudService`` against real CloudKit: the container
/// `iCloud.dev.ms-solutions.akari`, private and shared database.
///
/// Everything CloudKit brings in terms of types (`CKRecord`, `CKShare`, tokens)
/// stays in this file: to the outside go ``CloudRecord``, ``ZoneID`` and `Data`
/// as token or seal. The system fields of a `CKRecord` (with the change tag) are
/// archived as the seal and turned back into the record on the next save, so
/// `ifServerRecordUnchanged` stays effective across a restart.
///
/// **Fields:** text → `String`, integer → `Int64`, decimal number → `Double`,
/// time → `Date`, truth → `Int64` (CloudKit has none), bytes → `Data` (under
/// 1 MB; our records are bytes to kilobytes). Plus `geaendert` as a field of its
/// own, the clock of the ``MergeRule``.
///
/// **Errors** are mapped to ``CloudError``: network and rate → unreachable (the
/// zone waits), zone missing or deleted by the user → zone missing, account → no
/// account, rights/quota/unknown field → rejected with reason (which then appears
/// in the diagnostics line; "field unknown" means: schema not in production).
/// **When saving**, a schema error hits only its own record: it comes back as
/// ``StoreResult/rejected(_:)``, see ``affectsOnlyTheRecord(_:)``.
public struct CloudKitService: CloudService {

    static let changedField = "geaendert"

    private let container: CKContainer
    /// See ``CloudService/environment``.
    public let environment: String?
    private let privateSubscription: String
    private let sharedSubscription: String

    /// - Parameters:
    ///   - container: The container identifier of this app, such as
    ///     `iCloud.dev.ms-solutions.akari`. **No default, and that is intentional:**
    ///     since this package lives in `Bedrock`, several apps use it. A default would
    ///     mean the app that forgets it silently writes into another app's
    ///     container: no error, no message, foreign data. Same rule as for
    ///     `ContentSource.listChanges()`.
    ///   - subscriptionPrefix: The name prefix of the two database subscriptions
    ///     (`<prefix>-privat`, `<prefix>-geteilt`). **It must never change:** a new
    ///     name creates a second subscription instead of replacing the existing one,
    ///     and then every silent push arrives twice.
    ///   - environment: The CloudKit environment of this build (`"Production"`,
    ///     `"Development"`), as it appears in the entitlements, or `nil` if the app
    ///     does not specify it; then the environment guard of the ``ProfileZone`` stays
    ///     off. **No default**, for the same reason as with the container: an app
    ///     should decide.
    public init(container: String, subscriptionPrefix: String, environment: String?) {
        self.container = CKContainer(identifier: container)
        self.environment = environment
        self.privateSubscription = "\(subscriptionPrefix)-privat"
        self.sharedSubscription = "\(subscriptionPrefix)-geteilt"
    }

    private func database(_ zone: ZoneID) -> CKDatabase {
        zone.shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    private func database(shared: Bool) -> CKDatabase {
        shared ? container.sharedCloudDatabase : container.privateCloudDatabase
    }

    private func zoneID(_ zone: ZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.name, ownerName: zone.owner ?? CKCurrentUserDefaultName)
    }

    private func identifier(_ id: CKRecordZone.ID, shared: Bool) -> ZoneID {
        ZoneID(name: id.zoneName, owner: shared ? id.ownerName : nil)
    }

    // MARK: - Account

    public func accountStatus() async -> AccountStatus {
        switch try? await container.accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted, .temporarilyUnavailable: .restricted
        default: .unknown
        }
    }

    public func accountChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged).map({ _ in
                    ()
                }) {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Zones

    /// The new API reports the failure of a zone **in the result**, not as a throw.
    /// Whoever writes only `try` takes a never-created zone for created
    /// ("Share not saved" for no reason).
    public func createNew(_ zone: ZoneID) async throws(CloudError) {
        do {
            let (results, _) = try await database(zone).modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID(zone))], deleting: [])
            if case .failure(let failure)? = results[zoneID(zone)] { throw CloudError(failure) }
        } catch let failure as CloudError {
            throw failure
        } catch { throw CloudError(error) }
    }

    public func erase(_ zone: ZoneID) async throws(CloudError) {
        do {
            _ = try await database(zone).modifyRecordZones(saving: [], deleting: [zoneID(zone)])
        } catch {
            let failure = CloudError(error)
            if failure != .zoneMissing, failure != .deletedByUser { throw failure }
        }
    }

    public func zones(shared: Bool) async throws(CloudError) -> [ZoneID] {
        do {
            return try await database(shared: shared).allRecordZones().map {
                identifier($0.zoneID, shared: shared)
            }
        } catch { throw CloudError(error) }
    }

    public func databaseChanges(
        shared: Bool, since marker: Data?
    ) async throws(CloudError)
        -> DatabaseChanges
    {
        let db = database(shared: shared)
        let start = CloudKitService.token(marker)
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let op = CKFetchDatabaseChangesOperation(previousServerChangeToken: start)
                let collector = Collector()
                op.recordZoneWithIDChangedBlock = { id in
                    collector.changed.append(identifier(id, shared: shared))
                }
                op.recordZoneWithIDWasDeletedBlock = { id in
                    collector.deleted.append(identifier(id, shared: shared))
                }
                // **Deleted and deleted by the user are kept apart:** "purged" is deleting in the
                // iOS settings, and the loss of the encrypted data is likewise an act of the
                // human; see ``CloudError/deletedByUser``.
                op.recordZoneWithIDWasPurgedBlock = { id in
                    collector.deleted.append(identifier(id, shared: shared))
                    collector.byUser.append(identifier(id, shared: shared))
                }
                op.recordZoneWithIDWasDeletedDueToUserEncryptedDataResetBlock = { id in
                    collector.deleted.append(identifier(id, shared: shared))
                    collector.byUser.append(identifier(id, shared: shared))
                }
                op.fetchDatabaseChangesResultBlock = { result in
                    switch result {
                    case .success(let (token, _)):
                        continuation.resume(
                            returning: DatabaseChanges(
                                changed: collector.changed, deleted: collector.deleted,
                                deletedByUser: collector.byUser,
                                marker: CloudKitService.data(token)))
                    case .failure(let failure): continuation.resume(throwing: failure)
                    }
                }
                op.qualityOfService = .userInitiated
                db.add(op)
            }
        } catch {
            let failure = CloudError(error)
            if case CKError.changeTokenExpired = error, marker != nil {
                return try await databaseChanges(shared: shared, since: nil)
            }
            throw failure
        }
    }

    // MARK: - Records

    public func changes(_ zone: ZoneID, since marker: Data?) async throws(CloudError) -> Changes {
        let db = database(zone)
        let id = zoneID(zone)
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = CloudKitService.token(marker)
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let op = CKFetchRecordZoneChangesOperation(
                    recordZoneIDs: [id], configurationsByRecordZoneID: [id: configuration])
                let collector = Collector()
                op.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result, record.recordType != CKRecord.SystemType.share {
                        collector.cloudRecords.append(CloudKitService.fromCKRecord(record))
                    }
                }
                op.recordWithIDWasDeletedBlock = { recordID, type in
                    collector.names.append(RecordName(type: type, name: recordID.recordName))
                }
                op.recordZoneFetchResultBlock = { _, result in
                    switch result {
                    case .success(let (token, _, _)): collector.marker = CloudKitService.data(token)
                    case .failure(let failure): collector.failure = failure
                    }
                }
                op.fetchRecordZoneChangesResultBlock = { result in
                    if let failure = collector.failure {
                        continuation.resume(throwing: failure)
                        return
                    }
                    switch result {
                    case .success:
                        continuation.resume(
                            returning: Changes(
                                changed: collector.cloudRecords, deleted: collector.names,
                                marker: collector.marker))
                    case .failure(let failure): continuation.resume(throwing: failure)
                    }
                }
                op.qualityOfService = .userInitiated
                db.add(op)
            }
        } catch {
            if case CKError.changeTokenExpired = error, marker != nil {
                return try await changes(zone, since: nil)
            }
            throw CloudError(error)
        }
    }

    public func fetchRecords(
        _ names: [RecordName], in zone: ZoneID
    ) async throws(CloudError)
        -> [CloudRecord]
    {
        let id = zoneID(zone)
        do {
            let results = try await database(zone).records(
                for: names.map { CKRecord.ID(recordName: $0.name, zoneID: id) })
            return results.values.compactMap { result in
                if case .success(let record) = result { return CloudKitService.fromCKRecord(record) }
                return nil
            }
        } catch { throw CloudError(error) }
    }

    public func persist(
        _ cloudRecords: [CloudRecord], in zone: ZoneID
    ) async throws(CloudError)
        -> [StoreResult]
    {
        let id = zoneID(zone)
        let records = cloudRecords.map { CloudKitService.record($0, zone: id) }
        do {
            let (stored, _) = try await database(zone).modifyRecords(
                saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            return try CloudKitService.results(records.map(\.recordID), stored)
        } catch let failure as CloudError {
            throw failure
        } catch { throw CloudError(error) }
    }

    /// The answer of `modifyRecords` per sent record, in the order of the
    /// identifiers.
    ///
    /// **All rejected, none through: then it was the request.**
    /// `serverRejectedRequest` is in ``affectsOnlyTheRecord(_:)`` because older
    /// systems report the missing schema of *one* type that way. The same code also
    /// appears when the server rejects the whole request and puts it into every
    /// single result; the whole batch would then drop out of the queue record by
    /// record as rejected. So if at least two records carry this code and not one
    /// went through, the batch as a whole throws, and the queue stays put.
    static func results(
        _ identifiers: [CKRecord.ID], _ stored: [CKRecord.ID: Result<CKRecord, any Error>]
    ) throws(CloudError) -> [StoreResult] {
        let refused = identifiers.compactMap { identifier -> (any Error)? in
            guard case .failure(let failure) = stored[identifier],
                (failure as? CKError)?.code == .serverRejectedRequest
            else { return nil }
            return failure
        }
        if identifiers.count >= 2, refused.count == identifiers.count, let firstOne = refused.first {
            throw CloudError(firstOne)
        }
        return try identifiers.map { identifier throws(CloudError) -> StoreResult in
            switch stored[identifier] {
            case .success(let new): return .stored(CloudKitService.fromCKRecord(new))
            case .failure(let failure):
                if let ck = failure as? CKError {
                    if ck.code == .serverRecordChanged, let server = ck.serverRecord {
                        return .conflict(server: CloudKitService.fromCKRecord(server))
                    }
                    if ck.code == .unknownItem { return .vanished }
                    if CloudKitService.affectsOnlyTheRecord(ck) {
                        return .rejected("\(ck.localizedDescription) (CKError \(ck.code.rawValue))")
                    }
                }
                throw CloudError(failure)
            case nil: return .vanished
            }
        }
    }

    /// Whether an error **from the result of a single record** concerns only that
    /// record. It then goes back as ``StoreResult/rejected(_:)``, and the other
    /// records of the batch remain saved.
    ///
    /// **The list is narrow, and that is intentional.** CloudKit puts errors of the
    /// whole request or of the zone (network, account, quota, rights, zone missing)
    /// *also* into the result per record; such an error treated as a single error
    /// would mean throwing the whole batch out of the queue. So only the codes that
    /// depend on the content of a record are here:
    /// - `invalidArguments` (12): "Cannot create new type … in production schema",
    ///   "Cannot create or modify field": the record type or a field is missing in
    ///   the production schema, or a field has a different type there.
    /// - `serverRejectedRequest` (15): older systems report the missing schema of a
    ///   type like this; in the result of *one record* it is its error. If all
    ///   records of a batch carry it, ``results(_:_:)`` throws for the whole batch.
    /// - `constraintViolation` (19), `referenceViolation` (31): uniqueness or
    ///   reference of this record.
    /// - `assetFileNotFound` (16), `assetFileModified` (17): the file of a field.
    static func affectsOnlyTheRecord(_ failure: CKError) -> Bool {
        switch failure.code {
        case .invalidArguments, .serverRejectedRequest, .constraintViolation, .referenceViolation,
            .assetFileNotFound, .assetFileModified:
            true
        default: false
        }
    }

    public func erase(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) {
        let id = zoneID(zone)
        do {
            let (_, deleted) = try await database(zone).modifyRecords(
                saving: [], deleting: names.map { CKRecord.ID(recordName: $0.name, zoneID: id) },
                savePolicy: .ifServerRecordUnchanged, atomically: false)
            for (_, result) in deleted {
                if case .failure(let failure) = result, (failure as? CKError)?.code != .unknownItem {
                    throw CloudError(failure)
                }
            }
        } catch let failure as CloudError {
            throw failure
        } catch { throw CloudError(error) }
    }

    // MARK: - Pushes

    public func subscribe() async throws(CloudError) {
        do {
            for (db, identifier) in [
                (container.privateCloudDatabase, privateSubscription),
                (container.sharedCloudDatabase, sharedSubscription),
            ] {
                let subscription = CKDatabaseSubscription(subscriptionID: identifier)
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                subscription.notificationInfo = info
                _ = try await db.modifySubscriptions(saving: [subscription], deleting: [])
            }
        } catch { throw CloudError(error) }
    }

    public func interpret(push: [AnyHashable: Any]) -> PushInterpretation? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: push),
            let db = notification as? CKDatabaseNotification
        else { return nil }
        return .database(shared: db.databaseScope == .shared)
    }

    // MARK: - The public database

    /// **No zone.** The public database knows only `CKRecordZone.default()`.
    private var mailbox: CKDatabase { container.publicCloudDatabase }

    public func createPublic(_ cloudRecord: CloudRecord) async throws(CloudError) {
        do {
            let record = Self.record(cloudRecord, zone: CKRecordZone.default().zoneID)
            _ = try await mailbox.modifyRecords(saving: [record], deleting: [])
        } catch { throw CloudError(error) }
    }

    public func readPublic(
        _ name: RecordName
    ) async throws(CloudError)
        -> CloudRecord?
    {
        do {
            let identifier = CKRecord.ID(
                recordName: name.name, zoneID: CKRecordZone.default().zoneID)
            let record = try await mailbox.record(for: identifier)
            guard record.recordType == name.type else { return nil }
            return Self.fromCKRecord(record)
        } catch let failure as CKError where failure.code == .unknownItem {
            // **A collected or expired mailbox is the normal case.** Whoever turns it into
            // an error makes the UI report a "disruption" where in truth nobody has
            // answered yet.
            return nil
        } catch { throw CloudError(error) }
    }

    public func erasePublic(_ name: RecordName) async throws(CloudError) {
        do {
            let identifier = CKRecord.ID(
                recordName: name.name, zoneID: CKRecordZone.default().zoneID)
            _ = try await mailbox.modifyRecords(saving: [], deleting: [identifier])
        } catch let failure as CKError where failure.code == .unknownItem {
            // The target of this call is already gone.
            return
        } catch { throw CloudError(error) }
    }

    // MARK: - Sharing

    /// **Anyone with the link, read and write**, not "invited only": on the QR path
    /// the link is the invitation, and nobody is looked up by Apple ID. With `.none`
    /// the share was invisible to the family Apple ID ("share not found", on an
    /// iPad). Whoever has the link can read along and write along, which is why only
    /// the owner shows it, and "End sharing" invalidates it. An existing share with
    /// narrower permission is adjusted.
    public func share(_ zone: ZoneID, title: String) async throws(CloudError) -> Sharing {
        if let existing = try await share(zone) {
            if existing.publicPermission == .readWrite { return CloudKitService.sharing(existing) }
            existing.publicPermission = .readWrite
            return try await saveShare(existing)
        }
        let share = CKShare(recordZoneID: zoneID(zone))
        share.publicPermission = .readWrite
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        return try await saveShare(share)
    }

    private func saveShare(_ share: CKShare) async throws(CloudError) -> Sharing {
        do {
            let (results, _) = try await container.privateCloudDatabase.modifyRecords(
                saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            switch results[share.recordID] {
            case .success(let stored)?:
                guard let new = stored as? CKShare else {
                    throw CloudError.miscellaneous(
                        String(
                            format: String(
                                localized: "cloud.error.shareWrongType",
                                defaultValue: "Share came back as %@", bundle: .main),
                            String(describing: Swift.type(of: stored))))
                }
                return CloudKitService.sharing(new)
            case .failure(let failure)?:
                // If a share already exists (another device was faster), the conflict brings it
                // along; then it is the result, not an error.
                if let ck = failure as? CKError, ck.code == .serverRecordChanged,
                    let there = ck.serverRecord as? CKShare
                {
                    return CloudKitService.sharing(there)
                }
                throw CloudError(failure)
            case nil:
                throw CloudError.miscellaneous(
                    String(
                        localized: "cloud.error.shareNoResult", defaultValue: "Share without result",
                        bundle: .main))
            }
        } catch let failure as CloudError {
            throw failure
        } catch { throw CloudError(error) }
    }

    public func sharing(_ zone: ZoneID) async throws(CloudError) -> Sharing? {
        guard let share = try await share(zone) else { return nil }
        return CloudKitService.sharing(share)
    }

    private func share(_ zone: ZoneID) async throws(CloudError) -> CKShare? {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
        do {
            return try await database(zone).record(for: id) as? CKShare
        } catch {
            if case CKError.unknownItem = error { return nil }
            throw CloudError(error)
        }
    }

    public func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
        guard let share = try await share(zone) else { return }
        guard let p = share.participants.first(where: { CloudKitService.identifier($0) == participant })
        else {
            return
        }
        share.removeParticipant(p)
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(
                saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        } catch { throw CloudError(error) }
    }

    public func endSharing(_ zone: ZoneID) async throws(CloudError) {
        guard let share = try await share(zone) else { return }
        do {
            _ = try await container.privateCloudDatabase.modifyRecords(
                saving: [], deleting: [share.recordID], savePolicy: .ifServerRecordUnchanged, atomically: true
            )
        } catch { throw CloudError(error) }
    }

    public func sharingMetadata(_ url: URL) async throws(CloudError) -> SharingMetadata {
        do {
            let meta = try await container.shareMetadata(for: url)
            let zoneID = meta.share.recordID.zoneID
            return SharingMetadata(
                url: url, zone: ZoneID(name: zoneID.zoneName, owner: zoneID.ownerName),
                ownerName: CloudKitService.name(meta.ownerIdentity),
                title: meta.share[CKShare.SystemFieldKey.title] as? String,
                accepted: meta.participantStatus == .accepted)
        } catch { throw CloudError(error) }
    }

    public func accept(_ metadata: SharingMetadata) async throws(CloudError) -> ZoneID {
        do {
            let meta = try await container.shareMetadata(for: metadata.url)
            if meta.participantStatus != .accepted {
                _ = try await container.accept(meta)
            }
            let zoneID = meta.share.recordID.zoneID
            return ZoneID(name: zoneID.zoneName, owner: zoneID.ownerName)
        } catch { throw CloudError(error) }
    }

    public func leave(_ zone: ZoneID) async throws(CloudError) {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID(zone))
        do {
            _ = try await container.sharedCloudDatabase.modifyRecords(
                saving: [], deleting: [id], savePolicy: .ifServerRecordUnchanged, atomically: true)
        } catch {
            let failure = CloudError(error)
            if failure != .zoneMissing, failure != .deletedByUser { throw failure }
        }
    }

    // MARK: - Translation

    /// Collects the callbacks of an operation: the blocks run one after another on
    /// the operation's queue; the lock is for the translator.
    private final class Collector: @unchecked Sendable {
        var cloudRecords: [CloudRecord] = []
        var names: [RecordName] = []
        var changed: [ZoneID] = []
        var deleted: [ZoneID] = []
        var byUser: [ZoneID] = []
        var marker: Data?
        var failure: (any Error)?
    }

    static func record(_ cloudRecord: CloudRecord, zone: CKRecordZone.ID) -> CKRecord {
        let record: CKRecord
        if let seal = cloudRecord.seal, let decoder = try? NSKeyedUnarchiver(forReadingFrom: seal),
            let from = CKRecord(coder: decoder)
        {
            record = from
        } else {
            record = CKRecord(
                recordType: cloudRecord.type,
                recordID: CKRecord.ID(recordName: cloudRecord.name, zoneID: zone))
        }
        for (name, value) in cloudRecord.fields {
            let raw: CKRecordValue =
                switch value {
                case .text(let t): t as CKRecordValue
                case .integer(let z): NSNumber(value: Int64(z))
                case .decimalNumber(let k): NSNumber(value: k)
                case .time(let z): z as CKRecordValue
                case .truth(let w): NSNumber(value: Int64(w ? 1 : 0))
                case .data(let d): d as CKRecordValue
                }
            // **A field is either encrypted or not, and that forever,** see
            // ``CloudRecord/encrypted``. The server rejects a field that was once created
            // in plain text and would now arrive encrypted; precisely for that reason the
            // decision sits on the record and not on a switch.
            if cloudRecord.encrypted.contains(name) {
                record.encryptedValues[name] = raw
            } else {
                record[name] = raw
            }
        }
        // **The clock stays in plain text.** An encrypted field carries no index, and
        // `geaendert` is the first thing one looks at in the dashboard.
        record[changedField] = cloudRecord.changed as CKRecordValue
        return record
    }

    static func fromCKRecord(_ record: CKRecord) -> CloudRecord {
        var fields: [String: FieldValue] = [:]
        var encrypted: Set<String> = []
        for name in record.allKeys() where name != changedField {
            // **Look in the secure compartment first, then in plain text.** An encrypted
            // field read through `record[name]` does not yield its value; conversely
            // `encryptedValues` yields nothing for an open field. This order is the safe
            // one: it cannot accidentally pass a secret on as plain text.
            let fromSecureStore = record.encryptedValues[name]
            if fromSecureStore != nil { encrypted.insert(name) }
            switch fromSecureStore ?? record[name] {
            case let t as String: fields[name] = .text(t)
            case let z as Date: fields[name] = .time(z)
            case let d as Data: fields[name] = .data(d)
            case let n as NSNumber:
                fields[name] =
                    String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f"
                    ? .decimalNumber(n.doubleValue) : .integer(n.intValue)
            default: break
            }
        }
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: encoder)
        return CloudRecord(
            type: record.recordType, name: record.recordID.recordName, fields: fields,
            changed: record[changedField] as? Date ?? record.modificationDate ?? Date(),
            seal: encoder.encodedData, creator: record.creatorUserRecordID?.recordName,
            encrypted: encrypted,
            // **The server's clock, and only from here.** It never goes out; see
            // ``CloudRecord/serverTime``.
            serverTime: record.modificationDate)
    }

    static func token(_ marker: Data?) -> CKServerChangeToken? {
        guard let marker else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: marker)
    }

    static func data(_ token: CKServerChangeToken?) -> Data? {
        guard let token else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func identifier(_ p: CKShare.Participant) -> String {
        p.userIdentity.userRecordID?.recordName ?? p.userIdentity.lookupInfo?.emailAddress
            ?? p.userIdentity.lookupInfo?.phoneNumber ?? UUID().uuidString
    }

    static func name(_ identity: CKUserIdentity) -> String? {
        if let share = identity.nameComponents {
            let name = PersonNameComponentsFormatter.localizedString(from: share, style: .default)
            if !name.isEmpty { return name }
        }
        return identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber
    }

    static func sharing(_ share: CKShare) -> Sharing {
        Sharing(
            url: share.url,
            participant: share.participants.map { p in
                Participant(
                    identifier: identifier(p), name: name(p.userIdentity), owner: p.role == .owner,
                    accepted: p.acceptanceStatus == .accepted, writing: p.permission == .readWrite)
            })
    }
}

extension CloudError {

    /// An error from CloudKit mapped to the six classes.
    init(_ failure: any Error) {
        if let own = failure as? CloudError {
            self = own
            return
        }
        guard let ck = failure as? CKError else {
            self = .miscellaneous(failure.localizedDescription)
            return
        }
        switch ck.code {
        case .notAuthenticated, .accountTemporarilyUnavailable: self = .noAccount
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            self = .unreachable
        case .zoneNotFound: self = .zoneMissing
        // **Kept apart from `zoneNotFound`,** see ``CloudError/deletedByUser``.
        case .userDeletedZone: self = .deletedByUser
        case .permissionFailure, .quotaExceeded, .invalidArguments, .badContainer, .missingEntitlement:
            self = .rejected("\(ck.localizedDescription) (CKError \(ck.code.rawValue))")
        case .partialFailure:
            let inner = (ck.partialErrorsByItemID ?? [:]).values.compactMap { $0 as? CKError }
            if let firstOne = inner.first(where: { $0.code != .batchRequestFailed }) {
                self = CloudError(firstOne)
            } else {
                self = .miscellaneous(ck.localizedDescription)
            }
        default: self = .miscellaneous("\(ck.localizedDescription) (CKError \(ck.code.rawValue))")
        }
    }
}
