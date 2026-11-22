import Bedrock
import Foundation
import SourcesKit

/// Where the accounts live: in the keychain, one entry per ``AccountSlot``.
///
/// Phrased as a `KeyValueStore` so tests run with `InMemoryStore` — the real keychain
/// stays on the machine as soon as it expects a prompt. The three servers have one
/// slot each; the OPDS slots are kept in a list (`konto.opds.liste`) because the
/// keychain cannot enumerate.
///
/// **With a prefix since profiles:** Every profile has its own accounts, and they
/// live under `profil.<id>.konto.…` (``ProfileStore/prefix``). The store without
/// prefix reads the old layout — only the ``ProfileMigration`` still needs that.
public struct AccountStore: Sendable {

    private let store: any KeyValueStore
    /// What precedes every key — `profil.1.` in production, empty in the old layout.
    public let prefix: String

    public init(store: any KeyValueStore = SecureStore(), prefix: String = "") {
        self.store = store
        self.prefix = prefix
    }

    /// The store of a profile.
    public init(store: any KeyValueStore = SecureStore(), profile: ProfileStore) {
        self.init(store: store, prefix: profile.prefix)
    }

    func listKey(_ provider: Provider) -> String { prefix + "konto.\(provider.rawValue).liste" }

    /// The key of a slot in this store — with prefix.
    func lookupKey(_ slot: AccountSlot) -> String { prefix + slot.lookupKey }

    /// The raw entry of a slot — for the migration, which moves without interpreting.
    func raw(_ slot: AccountSlot) -> String? { try? store.value(for: lookupKey(slot)) }

    /// Every key this store may have occupied — the migration and removing a profile
    /// walk them, because the keychain cannot enumerate.
    func usedKeys() -> [String] {
        var lookupKey: [String] = []
        for provider in Provider.server {
            for slot in slots(provider) { lookupKey.append(self.lookupKey(slot)) }
            if AccountSlot.multiple(provider) { lookupKey.append(listKey(provider)) }
        }
        return lookupKey
    }

    /// Takes a raw entry — the counterpart of ``raw(_:)``.
    func adopt(raw json: String, on slot: AccountSlot) throws {
        try store.set(json, for: lookupKey(slot))
        if AccountSlot.multiple(slot.provider) {
            var numbers = Set(slots(slot.provider).map(\.number))
            numbers.insert(slot.number)
            try writeList(slot.provider, numbers)
        }
    }

    /// Reads an entry; `nil` if none exists **or** the entry is no longer readable. An
    /// unreadable entry (older format) counts as none — signing in is the way back, not
    /// a crash at launch.
    public func entry(_ slot: AccountSlot) -> AccountEntry? {
        guard let json = try? store.value(for: lookupKey(slot)) else { return nil }
        return try? JSONDecoder().decode(AccountEntry.self, from: Data(json.utf8))
    }

    public func entry(_ provider: Provider) -> AccountEntry? {
        entry(.server(provider))
    }

    /// The slots of a provider with several — from the list; without a list but with an
    /// entry under `konto.opds` (earlier builds), that is the one slot 0.
    public func slots(_ provider: Provider) -> [AccountSlot] {
        guard AccountSlot.multiple(provider) else { return [.server(provider)] }
        if let json = try? store.value(for: listKey(provider)),
            let numbers = try? JSONDecoder().decode([Int].self, from: Data(json.utf8))
        {
            return numbers.sorted().map { AccountSlot(provider, number: $0) }
        }
        return entry(.server(provider)) == nil ? [] : [.server(provider)]
    }

    public func all() -> [AccountSlot: AccountEntry] {
        var map: [AccountSlot: AccountEntry] = [:]
        for provider in Provider.server {
            for slot in slots(provider) {
                if let e = entry(slot) { map[slot] = e }
            }
        }
        return map
    }

    public func persist(_ entry: AccountEntry, on slot: AccountSlot) throws {
        let data = try JSONEncoder().encode(entry)
        guard let json = String(data: data, encoding: .utf8) else { throw SecureStore.Failure.malformed }
        try store.set(json, for: lookupKey(slot))
        if AccountSlot.multiple(slot.provider) {
            var numbers = Set(slots(slot.provider).map(\.number))
            numbers.insert(slot.number)
            try writeList(slot.provider, numbers)
        }
    }

    public func remove(_ slot: AccountSlot) throws {
        try store.remove(lookupKey(slot))
        if AccountSlot.multiple(slot.provider) {
            var numbers = Set(slots(slot.provider).map(\.number))
            numbers.remove(slot.number)
            try writeList(slot.provider, numbers)
        }
    }

    private func writeList(_ provider: Provider, _ numbers: Set<Int>) throws {
        let data = try JSONEncoder().encode(numbers.sorted())
        try store.set(String(decoding: data, as: UTF8.self), for: listKey(provider))
    }
}
