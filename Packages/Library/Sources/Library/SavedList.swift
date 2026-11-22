import CloudSync
import CryptoKit
import Foundation
import Observation
import SourcesKit

/// The saved list — "what I want to read next", in the order the
/// user drags (requested): the topmost entry is the candidate
/// for Home.
///
/// **Lives in the app, not on a server**: Komga knows
/// no user-specific saved list, and a reading list that all accounts see is
/// not "mine". The entries carry their source in the identifier — the list
/// is thereby per account without having to know it; what is signed out is not shown by the
/// shelf any more, and the identifier stays until the account comes back.
///
/// **Per profile, and via the profile zone in CloudKit** (formerly the
/// iCloud keychain per profile name): every entry is a record
/// `Merkeintrag` in the zone — name scattered from the identifier (the same title is on
/// both devices the same record), fields `kennung` (the identifier as JSON),
/// `reihenfolge`, `zeit`. Two devices thus **merge** by themselves: what only
/// one saved is added; what one forgot drops; the order
/// comes from the younger drag. The mirror in `UserDefaults` stands at once,
/// the zone brings the state from the other device and reports it via the
/// observation. Grimmory's shelf "Favorites" is mirrored by the `LibraryService`
/// additionally — the list here knows nothing of it.
@MainActor
@Observable
public final class SavedList {

    public static let storeKey = "gemerkt"
    /// The record type in the zone.
    public static let type = "Merkeintrag"

    public private(set) var entries: [SaveTarget]

    private let persistence: UserDefaults
    private let cloud: ProfileZone?
    private var observation: ObservationToken?

    /// The old iCloud key of a profile (`profil.<name>.gemerkt`) — only for the
    /// migration.
    public static func cloudKey(profile name: String) -> String { "profil.\(name).gemerkt" }

    /// - Parameters:
    ///   - persistence: the profile's UserDefaults
    ///   - cloud: the profile's zone; `nil` in tests and previews without iCloud
    ///   - legacyData: the old key in the iCloud keychain, to be fetched once
    public init(
        persistence: UserDefaults = .standard, cloud: ProfileZone? = nil, legacyData: LegacyData? = nil
    ) {
        self.persistence = persistence
        self.cloud = cloud
        let data = persistence.data(forKey: SavedList.storeKey)
        self.entries = data.flatMap { try? JSONDecoder().decode([SaveTarget].self, from: $0) } ?? []
        guard let cloud else { return }
        if let legacyData, let old = legacyData.data() {
            if let targets = try? JSONDecoder().decode([SaveTarget].self, from: old) {
                for target in targets where !entries.contains(target) { entries.append(target) }
            }
            legacyData.remove()
        }
        // The state of the zone and the own one, merged: what the zone knows, in its
        // order; what is only here (saved before the zone existed), at the end, and pushed up.
        let there = SavedList.targets(from: cloud.allRecords(ofType: SavedList.type))
        var merged = there
        for target in entries where !merged.contains(target) { merged.append(target) }
        entries = merged
        write(onlyNew: there)
        observation = cloud.observe(SavedList.type) { [weak self] records in self?.adopt(records) }
    }

    public func contains(_ target: SaveTarget) -> Bool { entries.contains(target) }

    /// Appends at the end — the order above is the one the user dragged;
    /// new things do not push in front.
    public func save(_ target: SaveTarget) {
        guard !entries.contains(target) else { return }
        entries.append(target)
        write()
    }

    public func forget(_ target: SaveTarget) {
        guard let i = entries.firstIndex(of: target) else { return }
        entries.remove(at: i)
        write(deleted: [target])
    }

    /// Like `move(fromOffsets:toOffset:)` in SwiftUI — `target` is the position before
    /// removal, as the list reports it. Without SwiftUI, because the package
    /// knows none.
    public func move(from source: IndexSet, to target: Int) {
        let moved = source.sorted().compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !moved.isEmpty else { return }
        let before = source.filter { $0 < target }.count
        var remainder = entries
        for i in source.sorted(by: >) where remainder.indices.contains(i) { remainder.remove(at: i) }
        let spot = min(max(target - before, 0), remainder.count)
        remainder.insert(contentsOf: moved, at: spot)
        guard remainder != entries else { return }
        entries = remainder
        write()
    }

    public func remove(at spots: IndexSet) {
        var remainder = entries
        var route: [SaveTarget] = []
        for i in spots.sorted(by: >) where remainder.indices.contains(i) {
            route.append(remainder.remove(at: i))
        }
        entries = remainder
        write(deleted: route)
    }

    /// The sync with a server that keeps a saved list: for the titles of this
    /// source what the server says holds — what is missing there drops; what is new there
    /// goes to the end. The order of the known stays. Series entries are known to
    /// no server; they stay untouched.
    public func adopt(_ server: Set<TitleID>, source: SourceID) {
        var new = entries.filter { target in
            guard case .title(let k) = target, k.source == source else { return true }
            return server.contains(k)
        }
        let known = Set(new)
        for identifier in server.sorted(by: { $0.id < $1.id }) where !known.contains(.title(identifier)) {
            new.append(.title(identifier))
        }
        guard new != entries else { return }
        let route = entries.filter { !new.contains($0) }
        entries = new
        write(deleted: route)
    }

    // MARK: - Mirror and zone

    /// Writes the UserDefaults and — per entry whose place has changed —
    /// the zone. `onlyNew` are the entries that already stand so in the zone and
    /// do not have to go up again.
    private func write(deleted: [SaveTarget] = [], onlyNew alreadyThere: [SaveTarget]? = nil) {
        if let data = try? JSONEncoder().encode(entries) {
            persistence.set(data, forKey: SavedList.storeKey)
        }
        guard let cloud else { return }
        for target in deleted { cloud.erase(type: SavedList.type, name: SavedList.name(target)) }
        for (slot, target) in entries.enumerated() {
            if let alreadyThere, alreadyThere.indices.contains(slot), alreadyThere[slot] == target {
                continue
            }
            let name = SavedList.name(target)
            if cloud.record(type: SavedList.type, name: name)?["reihenfolge"]?.integer == slot { continue }
            guard let identifier = try? JSONEncoder().encode(target) else { continue }
            cloud.write(
                CloudRecord(
                    type: SavedList.type, name: name,
                    fields: [
                        "kennung": .text(String(decoding: identifier, as: UTF8.self)),
                        "reihenfolge": .integer(slot),
                        "zeit": .time(Date()),
                    ]))
        }
    }

    /// From remote: the zone is the truth — order and stock.
    private func adopt(_ records: [CloudRecord]) {
        let new = SavedList.targets(from: records)
        guard new != entries else { return }
        entries = new
        if let data = try? JSONEncoder().encode(entries) {
            persistence.set(data, forKey: SavedList.storeKey)
        }
    }

    /// The targets from the records, by order, ties by time.
    static func targets(from records: [CloudRecord]) -> [SaveTarget] {
        records.compactMap { record -> (SaveTarget, Int, Date)? in
            guard let text = record["kennung"]?.text,
                let target = try? JSONDecoder().decode(SaveTarget.self, from: Data(text.utf8))
            else { return nil }
            return (target, record["reihenfolge"]?.integer ?? Int.max, record["zeit"]?.time ?? record.changed)
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .map(\.0)
    }

    /// The record name of a target — the identifier scattered, because an OPDS title
    /// carries a long JSON identifier and CloudKit allows 255 characters.
    static func name(_ target: SaveTarget) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let identifier = (try? encoder.encode(target)) ?? Data()
        return SHA256.hash(data: identifier).map { String(format: "%02x", $0) }.joined()
    }
}
