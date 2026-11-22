import Bedrock
import CloudSync
import Foundation
import Observation
import SourcesKit

/// Why a profile switch or creation failed — carries what the user needs to know
/// (two attempts left; locked until when).
public enum ProfileError: Error, Sendable, Hashable {
    case pinWrong(remaining: Int)
    case locked(until: Date)
    /// Not four digits.
    case pinInvalid
    /// The last profile stays — a device without a profile does not exist.
    case lastProfile
    case unknown
}

/// The profiles on this device — who is reading, who else is there, and switching.
///
/// Main-actor bound because the shell depends on it and rebuilds accounts, library,
/// saved list and theme on every switch. The list lives in the keychain, not in
/// UserDefaults: accounts survive deleting the app there, and a profile that could no
/// longer find its accounts would be a sign-in nobody understands. The active profile
/// lives in UserDefaults — after a fresh start the first one is good enough.
///
/// **The first launch with profiles is the ``ProfileMigration``:** No list in the
/// keychain means everything that existed so far becomes profile 1 — named after the
/// first account (the user name, without domain), otherwise the device name. An empty
/// device gets the same profile 1, just empty; the setup code renames it after the
/// person (``rename(to:ifUntouched:)``).
@MainActor
@Observable
public final class ProfileRegistry {

    public private(set) var all: [Profile]
    public private(set) var active: Profile
    /// The next number — only ever counts up, so a removed number never comes back
    /// and a leftover in the keychain never belongs to a new profile.
    private var next: Int

    private let store: any KeyValueStore
    private let settings: UserDefaults
    private let root: URL
    private let suites: @Sendable (Int) -> String
    private let lockout: PinProtection.Lock

    /// What lives in the keychain: the profiles and the counter.
    private struct StoredList: Codable {
        var profiles: [Profile]
        var next: Int

        enum CodingKeys: String, CodingKey, CaseIterable {
            case profiles = "profile"
            case next = "naechste"
        }
    }

    static let listKey = "profile.liste"
    static let activeKey = "profile.aktiv"

    /// - Parameters:
    ///   - store: the keychain — `InMemoryStore` in tests
    ///   - settings: the shared UserDefaults (active profile, lockout)
    ///   - root: the `profile/` folder — tests pass one under `tmp`
    ///   - suites: the UserDefaults suite name per profile — tests pass their own so
    ///     nothing is left behind in `~/Library/Preferences`
    ///   - deviceName: the name of profile 1 when no account supplies one
    ///   - migration: what moves along with the accounts on first launch
    public init(
        store: any KeyValueStore = SecureStore(), settings: UserDefaults = .standard,
        root: URL = ProfileStore.root, suites: (@Sendable (Int) -> String)? = nil,
        deviceName: String = DeviceName.thisDevice,
        migration: ProfileMigration.Plan = ProfileMigration.Plan(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.settings = settings
        self.root = root
        self.suites = suites ?? { ProfileStore.suite($0) }
        self.lockout = PinProtection.Lock(persistence: settings, clock: clock)
        let read = ProfileRegistry.readList(store)
        var list = read ?? StoredList(profiles: [], next: 2)
        if list.profiles.isEmpty {
            let persistence = ProfileStore(
                profile: 1, suite: self.suites(1),
                folder: root.appending(path: "1", directoryHint: .isDirectory))
            let accounts = ProfileMigration(plan: migration).execute(
                store: store, from: settings, to: persistence)
            let name = ProfileRegistry.name(from: accounts) ?? deviceName
            list = StoredList(
                profiles: [Profile(id: 1, name: name, color: "tinte", protected: false)], next: 2)
            Diagnostics.step(
                "Profiles: migrated to profile 1 (\(name)), \(accounts.count) accounts", since: nil,
                area: "Profile")
        }
        let saved = settings.integer(forKey: ProfileRegistry.activeKey)
        all = list.profiles
        next = list.next
        active = list.profiles.first { $0.id == saved } ?? list.profiles[0]
        if read == nil { writeList() }
    }

    // MARK: - Reading

    /// The storage of a profile — prefix, suite, folder.
    public func persistence(_ profile: Profile) -> ProfileStore {
        ProfileStore(
            profile: profile.id, suite: suites(profile.id),
            folder: root.appending(path: "\(profile.id)", directoryHint: .isDirectory))
    }

    /// The storage of the active profile.
    public var activeStore: ProfileStore { persistence(active) }

    /// Whether a child profile exists while an adult profile has no PIN — the hint when
    /// creating a child profile, because a barrier you can bypass by tapping the other
    /// circle is none.
    public var adultsWithoutPin: [Profile] {
        guard all.contains(where: \.kind) else { return [] }
        return all.filter { !$0.kind && !$0.protected }
    }

    /// Until when a profile is locked after three failed attempts.
    public func lockedUntil(_ profile: Profile) -> Date? { lockout.lockedUntil(profile.id) }

    // MARK: - Switching

    /// Switches — for a protected profile only with the right PIN. The third failed
    /// attempt locks for 30 seconds; the right one resets the count.
    public func switchTo(to profile: Profile, pin: String? = nil) throws(ProfileError) {
        guard let target = all.first(where: { $0.id == profile.id }) else { throw .unknown }
        if target.protected, target.id != active.id {
            try check(pin: pin ?? "", for: target)
        }
        activate(target)
    }

    /// Checks a profile's PIN, with counting and lockout — for switching and for
    /// "Manage" of a protected profile.
    public func check(pin: String, for profile: Profile) throws(ProfileError) {
        if let until = lockout.lockedUntil(profile.id) { throw .locked(until: until) }
        guard let entry = try? store.value(for: pinKey(profile)), PinProtection.matches(pin, to: entry)
        else {
            lockout.failedAttempt(profile.id)
            if let until = lockout.lockedUntil(profile.id) { throw .locked(until: until) }
            throw .pinWrong(remaining: lockout.remaining(profile.id))
        }
        lockout.erase(profile.id)
    }

    private func activate(_ profile: Profile) {
        active = profile
        settings.set(profile.id, forKey: ProfileRegistry.activeKey)
    }

    // MARK: - Creating and changing

    /// Creates a profile — with the next free number, never an old one — and does not
    /// make it active: whoever creates one for a child stays themselves for now.
    @discardableResult
    public func create(
        to name: String, color: String, maxAge: Int? = nil, pin: String? = nil
    )
        throws(ProfileError) -> Profile
    {
        if let pin, !PinProtection.valid(pin) { throw .pinInvalid }
        let identifier = next
        next += 1
        var profile = Profile(
            id: identifier, name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color,
            maxAge: maxAge)
        if let pin {
            try? store.set(PinProtection.mint(pin), for: pinKey(profile))
            profile.protected = true
        }
        all.append(profile)
        writeList()
        return profile
    }

    /// Takes over name, color and maximum age — the PIN goes through ``setPin(_:for:)``.
    public func change(_ profile: Profile) {
        guard let i = all.firstIndex(where: { $0.id == profile.id }) else { return }
        all[i].name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        all[i].color = profile.color
        all[i].maxAge = profile.maxAge
        if active.id == profile.id { active = all[i] }
        writeList()
    }

    // MARK: - Cloud

    /// Remembers a profile's zone — once, on first binding.
    public func bind(_ profile: Profile, to zone: ZoneID) {
        guard let i = all.firstIndex(where: { $0.id == profile.id }), all[i].cloud != zone else { return }
        all[i].cloud = zone
        if active.id == profile.id { active = all[i] }
        writeList()
    }

    /// The "sync via iCloud" switch — off also means: no zone remembered anymore
    /// (the UI cleans up the zone itself before flipping it here).
    public func setCloudSync(_ to: Bool, for profile: Profile) {
        guard let i = all.firstIndex(where: { $0.id == profile.id }) else { return }
        all[i].cloudSync = to
        if !to, !all[i].shared { all[i].cloud = nil }
        if active.id == profile.id { active = all[i] }
        writeList()
    }

    /// An accepted profile: name, color and initial from the owner, the zone in the
    /// shared database. If the profile (same zone) already exists, that one is returned.
    @discardableResult
    public func createShared(
        to name: String, color: String, zone: ZoneID, from owner: String?
    ) -> Profile {
        if let da = all.first(where: { $0.cloud == zone }) { return da }
        let identifier = next
        next += 1
        let profile = Profile(
            id: identifier, name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color,
            cloud: zone,
            sharedBy: owner)
        all.append(profile)
        writeList()
        return profile
    }

    // MARK: Adopting a share

    /// The local profile that matches a share — the same reader as on the owner's
    /// device, just without its zone: not shared and the same name after
    /// ``CloudHub/normalized(_:)`` (case and whitespace do not count). The family iPad
    /// already had "reader" with its own reading time and saved list before the code
    /// arrived from the iPhone — that is to be adopted, not sit alongside.
    public func matchingLocal(to name: String) -> Profile? {
        let wanted = CloudHub.normalized(name)
        return all.first { !$0.shared && CloudHub.normalized($0.name) == wanted }
    }

    /// Activates a profile **without PIN** — only for adoption: whoever presents the
    /// owner's code holds their unlocked device; the PIN protects against the others on
    /// the family iPad, not against them. A running lockout is dropped too.
    public func activateForAdoption(_ profile: Profile) {
        guard let target = all.first(where: { $0.id == profile.id }) else { return }
        lockout.erase(target.id)
        activate(target)
    }

    /// Rebinds a local profile to the owner's zone: zone in the shared database,
    /// "shared by", sync on. Number, accounts, PIN and maximum age stay; the core sets
    /// the owner's name and color afterwards via ``change(_:)``.
    @discardableResult
    public func adoptSharing(_ profile: Profile, zone: ZoneID, from owner: String?) -> Profile {
        guard let i = all.firstIndex(where: { $0.id == profile.id }) else { return profile }
        all[i].cloud = zone
        all[i].sharedBy = owner
        all[i].cloudSync = true
        if active.id == profile.id { active = all[i] }
        writeList()
        return all[i]
    }

    /// Sets or removes (`nil`) the PIN.
    public func setPin(_ pin: String?, for profile: Profile) throws(ProfileError) {
        guard let i = all.firstIndex(where: { $0.id == profile.id }) else { throw .unknown }
        if let pin {
            guard PinProtection.valid(pin) else { throw .pinInvalid }
            try? store.set(PinProtection.mint(pin), for: pinKey(profile))
            all[i].protected = true
        } else {
            try? store.remove(pinKey(profile))
            all[i].protected = false
        }
        lockout.erase(profile.id)
        if active.id == profile.id { active = all[i] }
        writeList()
    }

    /// Renames the active profile after the person from the setup code — only while it
    /// is the only one and has no account yet: whoever already reads keeps their name.
    public func rename(to person: String, ifUntouched untouched: Bool) {
        let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, untouched, all.count == 1 else { return }
        var profile = active
        profile.name = name
        change(profile)
    }

    // MARK: - Removing

    /// Removes a profile with everything it has: accounts in the keychain, PIN, suite,
    /// folder. The last profile stays. If it was the active one, the first remaining one
    /// becomes active — without PIN, because whoever may remove is no child.
    public func remove(_ profile: Profile) throws(ProfileError) {
        guard all.count > 1 else { throw .lastProfile }
        guard all.contains(where: { $0.id == profile.id }) else { throw .unknown }
        let persistence = persistence(profile)
        let accounts = AccountStore(store: store, profile: persistence)
        for lookupKey in accounts.usedKeys() { try? store.remove(lookupKey) }
        try? store.remove(pinKey(profile))
        lockout.erase(profile.id)
        persistence.settings.removePersistentDomain(forName: persistence.suite)
        try? FileManager.default.removeItem(at: persistence.folder)
        all.removeAll { $0.id == profile.id }
        writeList()
        if active.id == profile.id { activate(all[0]) }
    }

    // MARK: - Helpers

    private func pinKey(_ profile: Profile) -> String { profile.prefix + "pin" }

    private static func readList(_ store: any KeyValueStore) -> StoredList? {
        guard let json = try? store.value(for: listKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode(StoredList.self, from: Data(json.utf8)), !list.profiles.isEmpty
        else { return nil }
        return list
    }

    private func writeList() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(StoredList(profiles: all, next: next)) else { return }
        try? store.set(String(decoding: data, as: UTF8.self), for: ProfileRegistry.listKey)
    }

    /// The name for profile 1 from the migrated accounts: the user name of the first
    /// server in tab-bar order, without domain — "reader" from `reader@example.test`.
    /// OPDS and WebDAV do not count; their name is often empty.
    static func name(from accounts: [AccountSlot: AccountEntry]) -> String? {
        for provider in Provider.server where !AccountSlot.multiple(provider) {
            guard let entry = accounts[.server(provider)] else { continue }
            let name = entry.account.username.split(separator: "@").first.map(String.init) ?? ""
            if !name.isEmpty { return name }
        }
        return nil
    }
}
