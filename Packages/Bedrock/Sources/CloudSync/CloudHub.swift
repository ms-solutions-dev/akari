import Bedrock
import Foundation
import Observation

/// This device as it registers itself in the zone (record `Geraet`), so that the
/// "iCloud & Devices" sheet can say who uses the zone. Apple knows only Apple IDs
/// as participants; the device list is our own bookkeeping.
public struct DeviceDescription: Sendable, Hashable {
    public let identifier: String
    public let name: String
    public let model: String

    public init(identifier: String, name: String, model: String) {
        self.identifier = identifier
        self.name = name
        self.model = model
    }
}

/// A device from the zone, for display. ``creator`` is the Apple ID that
/// registered it (this is how the sheet finds the devices of a participant),
/// ``named`` says that a human set the name, in which case the device no longer
/// writes its system name back.
public struct DeviceEntry: Sendable, Hashable, Identifiable {
    public let identifier: String
    public let name: String
    public let model: String
    public let recently: Date
    public let creator: String?
    public let named: Bool
    public var id: String { identifier }
}

/// What is settled after accepting a share: the zone in the shared database, who
/// gave it, and what the profile is called and looks like there.
public struct Accepted: Sendable, Hashable {
    public let zone: ZoneID
    public let ownerName: String?
    public let profileName: String?
    public let color: String?
}

/// The one place that knows the container: account status, the two database
/// subscriptions, the tokens of the databases, the live zones, and what a silent
/// push triggers. Also the **binding** of a profile to its zone and everything
/// around sharing.
///
/// **Binding (zone choice):** a profile that has no zone yet gets one with a new
/// identifier, **unless** the private database already holds a profile zone whose
/// record `Profileinstellung/name` carries the same name. Then it is the same
/// reader on the same Apple ID on another device, and the profile takes that
/// zone. After that only the identifier decides: renaming leaves the zone in
/// place, and a second "Alex" on the same device gets its own (the search asks
/// only unbound profiles).
///
/// **A silent push** says only "a database has changed". The hub then fetches the
/// database changes (which zones) and nudges the affected live zones; a revoked
/// or deleted zone is noted as lost.
@MainActor
@Observable
public final class CloudHub {

    public static let settingType = "Profileinstellung"
    public static let deviceType = "Geraet"
    public static let nameKey = "name"
    public static let colorKey = "farbe"
    public static let valueField = "wert"
    /// On the `Geraet`: `1` if a human set the name.
    public static let namedField = "benannt"
    /// The name of a participant, assigned by the owner: `Profileinstellung`
    /// `teilnehmer.<record name of the Apple ID>`. Apple reveals no identity for a
    /// share via link, so the reader names who it is.
    public static let participantPrefix = "teilnehmer."

    public let service: (any CloudService)?
    public private(set) var account: AccountStatus = .unknown
    public let device: DeviceDescription

    private let file: URL?
    private var tokens: [Bool: Data] = [:]
    private var subscribed = false
    private var zones: [ZoneHolder] = []
    private var accountWatch: Task<Void, Never>?

    private struct ZoneHolder {
        weak var zone: ProfileZone?
    }

    private struct Snapshot: Codable {
        var privateToken: Data?
        var sharedToken: Data?
        var subscribed: Bool
        /// See ``CloudService/environment``: change tokens apply only in their environment.
        var environment: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case privateToken = "privateMarke"
            case sharedToken = "geteilteMarke"
            case subscribed = "abonniert"
            case environment = "umgebung"
        }
    }

    /// - Parameters:
    ///   - service: the trip to the server; `nil` means: no iCloud in this run.
    ///   - file: where tokens and subscription state live (`Application Support/wolke.json`).
    ///   - device: this device for the record `Geraet`.
    public init(service: (any CloudService)?, file: URL?, device: DeviceDescription) {
        self.service = service
        self.file = file
        self.device = device
        restoreFromDisk()
    }

    public static var defaultFileName: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "wolke.json")
    }

    // MARK: - Start

    /// Account status, subscriptions, the account watch, and a first look into both
    /// databases. Once at launch; the pushes follow.
    public func launch() async {
        guard let service else { return }
        account = await service.accountStatus()
        if accountWatch == nil {
            accountWatch = Task { [weak self] in
                for await _ in service.accountChanges() {
                    await self?.accountChanged()
                }
            }
        }
        guard account == .available else { return }
        if !subscribed {
            do throws(CloudError) {
                try await service.subscribe()
                subscribed = true
                persist()
            } catch {
                Diagnostics.deficiency("Cloud: subscription failed — \(error)", since: nil, area: "Cloud")
            }
        }
        await checkDatabases()
    }

    /// The account changed: sign out, iCloud off for the app, sign in. The zones
    /// learn of it on their next pass; it is triggered here.
    public func accountChanged() async {
        guard let service else { return }
        let previously = account
        account = await service.accountStatus()
        Diagnostics.step("Cloud: account \(previously) → \(account)", since: nil, area: "Cloud")
        if account == .available {
            tokens = [:]
            subscribed = false
            await launch()
        }
        for zone in live { await zone.equalSince() }
    }

    public func register(_ zone: ProfileZone) {
        zones.removeAll { $0.zone == nil || $0.zone === zone }
        zones.append(ZoneHolder(zone: zone))
    }

    private var live: [ProfileZone] { zones.compactMap(\.zone) }

    // MARK: - Pushes

    /// A silent push: `true` if it came from CloudKit and there was something to fetch.
    public func process(push: [AnyHashable: Any]) async -> Bool {
        guard let service, let interpretation = service.interpret(push: push) else { return false }
        switch interpretation {
        case .database(let shared): await checkDatabase(shared: shared)
        }
        return true
    }

    /// Ask both databases for changed zones and nudge the live ones.
    public func checkDatabases() async {
        await checkDatabase(shared: false)
        await checkDatabase(shared: true)
    }

    private func checkDatabase(shared: Bool) async {
        guard let service else { return }
        do throws(CloudError) {
            let changes = try await service.databaseChanges(shared: shared, since: tokens[shared])
            tokens[shared] = changes.marker
            persist()
            for zone in live {
                guard let identifier = zone.zone, identifier.shared == shared else { continue }
                // **Deleted and then recreated** (for example after ``ProfileZone/drop()``) is
                // no longer a deletion; then the change counts.
                if changes.deleted.contains(identifier), !changes.changed.contains(identifier) {
                    if shared {
                        zone.noteLost()
                    } else {
                        // A zone of **our own**: do not revive it (``ProfileZone``).
                        zone.noteRemoved(
                            changes.deletedByUser.contains(identifier) ? .byUser : .fromRemote)
                    }
                } else if changes.changed.contains(identifier) {
                    await zone.equalSince()
                }
            }
        } catch {
            Diagnostics.deficiency(
                "Cloud: database \(shared ? "shared" : "private") — \(error)", since: nil, area: "Cloud")
        }
    }

    // MARK: - Binding

    /// Binds an unbound zone, found or new (see above). Returns the identifier the
    /// profile remembers; `nil` if there is no account (then the zone stays unbound
    /// and everything local).
    public func bind(_ zone: ProfileZone, identifier: UUID, name: String, color: String?) async -> ZoneID? {
        guard let service else { return nil }
        if let present = zone.zone {
            await syncAndRegister(zone, name: name, color: color)
            return present
        }
        account = await service.accountStatus()
        guard account == .available else { return nil }
        do throws(CloudError) {
            let wanted = CloudHub.normalized(name)
            for foreign in try await service.zones(shared: false) where foreign.isProfile {
                let records = try await service.fetchRecords(
                    [RecordName(type: CloudHub.settingType, name: CloudHub.nameKey)],
                    in: foreign)
                guard let there = records.first?[CloudHub.valueField]?.text,
                    CloudHub.normalized(there) == wanted
                else { continue }
                Diagnostics.step(
                    "Cloud: profile “\(name)” takes zone \(foreign.name)", since: nil, area: "Cloud")
                zone.bind(to: foreign)
                await syncAndRegister(zone, name: name, color: color)
                return foreign
            }
            let own = ZoneID(profile: identifier)
            try await service.createNew(own)
            zone.bind(to: own)
            await syncAndRegister(zone, name: name, color: color)
            return own
        } catch {
            Diagnostics.deficiency(
                "Cloud: binding “\(name)” failed — \(error)", since: nil, area: "Cloud")
            return nil
        }
    }

    private func syncAndRegister(_ zone: ProfileZone, name: String, color: String?) async {
        if zone.zone?.shared != true { writeName(name, color: color, in: zone) }
        writeDevice(in: zone)
        await zone.equalSince()
    }

    /// Name and color of the profile into the zone, for the other device's zone
    /// choice and for the profile a participant creates. Only if something changes.
    public func writeName(_ name: String, color: String?, in zone: ProfileZone) {
        let type = CloudHub.settingType
        if zone.record(type: type, name: CloudHub.nameKey)?[CloudHub.valueField]?.text != name {
            zone.write(
                CloudRecord(
                    type: type, name: CloudHub.nameKey,
                    fields: [CloudHub.valueField: .text(name)]))
        }
        if let color,
            zone.record(type: type, name: CloudHub.colorKey)?[CloudHub.valueField]?.text != color
        {
            zone.write(
                CloudRecord(
                    type: type, name: CloudHub.colorKey,
                    fields: [CloudHub.valueField: .text(color)]))
        }
    }

    /// This device into the zone, at most once an hour, so the sync does not produce
    /// a write request at every launch. If a human named the device
    /// (``namedField``), their name stays; only `zuletzt` moves.
    public func writeDevice(in zone: ProfileZone) {
        let present = zone.record(type: CloudHub.deviceType, name: device.identifier)
        let named = present?[CloudHub.namedField]?.truth == true
        let name = named ? (present?["name"]?.text ?? device.name) : device.name
        if let present, let recently = present["zuletzt"]?.time, Date().timeIntervalSince(recently) < 3600,
            present["name"]?.text == name
        {
            return
        }
        var fields: [String: FieldValue] = [
            "name": .text(name), "modell": .text(device.model), "zuletzt": .time(Date()),
        ]
        if named { fields[CloudHub.namedField] = .truth(true) }
        zone.write(CloudRecord(type: CloudHub.deviceType, name: device.identifier, fields: fields))
    }

    /// Rename a device: anyone with write permission may do so, even for a foreign
    /// device. The name stays afterwards (``namedField``). If the record does not
    /// exist yet (the own device right at joining), it is created with the name.
    public func renameDevice(_ identifier: String, name: String, in zone: ProfileZone) {
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return }
        var fields = zone.record(type: CloudHub.deviceType, name: identifier)?.fields ?? [:]
        if identifier == device.identifier {
            fields["modell"] = .text(device.model)
            fields["zuletzt"] = .time(Date())
        }
        guard fields["modell"] != nil else { return }
        fields["name"] = .text(new)
        fields[CloudHub.namedField] = .truth(true)
        zone.write(CloudRecord(type: CloudHub.deviceType, name: identifier, fields: fields))
    }

    /// Name a participant, as a `Profileinstellung` in the zone so every device of
    /// the owner sees the same name. An empty name deletes it.
    public func renameParticipant(_ identifier: String, name: String, in zone: ProfileZone) {
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let recordName = CloudHub.participantPrefix + identifier
        if new.isEmpty {
            zone.erase(type: CloudHub.settingType, name: recordName)
        } else {
            zone.write(
                CloudRecord(
                    type: CloudHub.settingType, name: recordName,
                    fields: [CloudHub.valueField: .text(new)]))
        }
    }

    /// The assigned name of a participant, `nil` if none is assigned.
    public static func participantName(_ identifier: String, in zone: ProfileZone) -> String? {
        zone.record(type: settingType, name: participantPrefix + identifier)?[valueField]?.text
    }

    /// The devices that use a zone, from the `Geraet` records.
    public static func devices(in zone: ProfileZone) -> [DeviceEntry] {
        zone.allRecords(ofType: deviceType).compactMap { record in
            guard let name = record["name"]?.text else { return nil }
            return DeviceEntry(
                identifier: record.name, name: name, model: record["modell"]?.text ?? "",
                recently: record["zuletzt"]?.time ?? record.changed, creator: record.creator,
                named: record[namedField]?.truth == true)
        }
        .sorted { $0.recently > $1.recently }
    }

    /// The devices of a participant: the ones they registered themselves
    /// (`___createdBy`). That is how the sheet says "iPad · joined via link" where
    /// Apple knows only "unknown".
    public static func devices(from participant: String, in zone: ProfileZone) -> [DeviceEntry] {
        devices(in: zone).filter { $0.creator == participant }
    }

    /// How the zone choice compares names: lowercase, trimmed, one space.
    public static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Sharing

    public func share(_ zone: ZoneID, title: String) async throws(CloudError) -> Sharing {
        guard let service else { throw .noAccount }
        return try await service.share(zone, title: title)
    }

    public func sharing(_ zone: ZoneID) async throws(CloudError) -> Sharing? {
        guard let service else { return nil }
        return try await service.sharing(zone)
    }

    public func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
        guard let service else { throw .noAccount }
        try await service.remove(participant: participant, from: zone)
    }

    public func endSharing(_ zone: ZoneID) async throws(CloudError) {
        guard let service else { throw .noAccount }
        try await service.endSharing(zone)
    }

    /// Accepts a share link and reads name and color of the profile from the zone.
    public func accept(url: URL) async throws(CloudError) -> Accepted {
        guard let service else { throw .noAccount }
        let meta = try await service.sharingMetadata(url)
        let zone = try await service.accept(meta)
        // **An own zone that does not exist here is a different iCloud environment:**
        // same Apple ID, but one device as a debug build ("Development"), the other from
        // TestFlight ("Production"). Until here that silently produced an empty zone,
        // and the profile arrived with a bare name. Now it is a clear error.
        if !zone.shared, !(try await service.zones(shared: false)).contains(zone) {
            Diagnostics.deficiency(
                "Share points to an own zone that does not exist here — different iCloud environment "
                    + "(development/TestFlight)? Here: \(service.environment ?? "unknown")",
                since: nil, area: "Cloud")
            throw .rejected(
                String(
                    localized: "cloud.error.zoneEnvironment",
                    defaultValue: "Zone not in this iCloud environment", bundle: .main))
        }
        let type = CloudHub.settingType
        let records = try await service.fetchRecords(
            [
                RecordName(type: type, name: CloudHub.nameKey),
                RecordName(type: type, name: CloudHub.colorKey),
            ], in: zone)
        return Accepted(
            zone: zone, ownerName: meta.ownerName,
            profileName: records.first { $0.name == CloudHub.nameKey }?[CloudHub.valueField]?
                .text,
            color: records.first { $0.name == CloudHub.colorKey }?[CloudHub.valueField]?.text)
    }

    /// Whether a link is an iCloud share link.
    ///
    /// The host must be `icloud.com` or end in `.icloud.com`; a bare
    /// `hasSuffix("icloud.com")` also let `evilicloud.com` through.
    public static func isShareLink(_ url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased()
        return (host == "icloud.com" || host.hasSuffix(".icloud.com")) && url.path.hasPrefix("/share")
    }

    /// Delete the zone of an own profile; data stays in the mirror.
    public func erase(_ zone: ZoneID) async throws(CloudError) {
        guard let service else { return }
        try await service.erase(zone)
    }

    public func leave(_ zone: ZoneID) async throws(CloudError) {
        guard let service else { return }
        try await service.leave(zone)
    }

    // MARK: - Disk

    private func restoreFromDisk() {
        guard let file, let data = try? Data(contentsOf: file),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        // **A different environment means: start over.** A change token from
        // "Development" is worthless in "Production", and a subscription there does not
        // exist yet.
        if let here = service?.environment, snapshot.environment != here { return }
        tokens[false] = snapshot.privateToken
        tokens[true] = snapshot.sharedToken
        subscribed = snapshot.subscribed
    }

    private func persist() {
        guard let file else { return }
        let snapshot = Snapshot(
            privateToken: tokens[false], sharedToken: tokens[true], subscribed: subscribed,
            environment: service?.environment)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
