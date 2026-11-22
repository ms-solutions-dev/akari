import AccountsKit
import Bedrock
import CloudSync
import DesignSystem
import Device
import Foundation
import Library
import Observation
import ReadingProgress
import SourcesKit
import SwiftUI

/// Everything that hangs on a profile, in one handle: accounts, library (with saved list
/// and queue), reading time, theme, the profile's UserDefaults, and the
/// ``CloudSync/ProfileZone`` through which saved list, theme and reading time travel between
/// devices.
///
/// The shell holds **one** context and swaps it out completely on switching, instead of
/// rebuilding five `@State` values one by one and forgetting one. What is not here
/// is shared: the offline store, network watch, player, the device source.
///
/// **The migration plan lives here** (``migrationPlan``), not in `AccountsKit`: this
/// package knows all keys by name (the saved list, theme, language,
/// the start row, translation, Wikipedia, recording reading time, the series choice) and
/// all the folders that used to lie loose under "Application Support" and `caches`.
@MainActor
@Observable
public final class ProfileContext {

    public let profile: Profile
    public let persistence: ProfileStore
    public let accounts: AccountRegistry
    public let inventory: LibraryService
    public let readingTime: ReadingTimeLog
    public let themes: ThemeChoice
    /// The profile's zone in CloudKit; `nil` in tests without cloud.
    public let cloud: ProfileZone?

    /// The profile's UserDefaults, for `@AppStorage` via `defaultAppStorage` and
    /// for everything that reads them by name. Held once, not rebuilt per call: the
    /// shell passes them to `defaultAppStorage` on every render, and `@AppStorage` attaches
    /// to the object.
    public let settings: UserDefaults
    /// Which podcasts notify about new episodes, on the profile's UserDefaults.
    public let notifications: NotificationChoice

    public init(
        profile: Profile, persistence: ProfileStore, accounts: AccountRegistry, inventory: LibraryService,
        readingTime: ReadingTimeLog, themes: ThemeChoice, cloud: ProfileZone? = nil
    ) {
        self.profile = profile
        self.persistence = persistence
        self.accounts = accounts
        self.inventory = inventory
        self.readingTime = readingTime
        self.themes = themes
        self.cloud = cloud
        self.settings = persistence.settings
        self.notifications = NotificationChoice(persistence: persistence.settings)
    }

    /// A profile's context in operation: keychain with prefix, the profile's folder,
    /// the zone (mirror under `profile/<id>/wolke.json`; without a service if
    /// the reader has switched sync off for this profile), saved list, theme and
    /// reading time on the zone, with the old key store as a transition.
    public static func standard(
        _ profile: Profile, persistence: ProfileStore, device: DeviceSource, hub: CloudHub,
        store: any KeyValueStore = SecureStore(), legacyStorage: (any KeyStorage)? = nil
    ) -> ProfileContext {
        let accounts = AccountRegistry(
            persistence: AccountStore(store: store, profile: persistence),
            trusts: CertificateTrustStore(store: store),
            states: persistence.states)
        let zone = ProfileZone(
            file: persistence.cloud, service: profile.cloudSync ? hub.service : nil, zone: profile.cloud)
        zone.sharedBy = profile.sharedBy
        hub.register(zone)
        let legacy = legacyStorage ?? NSUbiquitousKeyValueStore.default
        let savedList = SavedList(
            persistence: persistence.settings, cloud: zone,
            legacyData: LegacyData(legacy, lookupKey: SavedList.cloudKey(profile: profile.cloudName)))
        let inventory = LibraryService(
            persistence: LibraryStore(folder: persistence.inventory), savedList: savedList,
            settings: persistence.settings, queue: Queue(folder: persistence.progress),
            maxAge: profile.maxAge, catalog: ProfileContext.catalog(persistence.catalog)
        ) { accounts.allSources + [device] }
        return ProfileContext(
            profile: profile, persistence: persistence, accounts: accounts, inventory: inventory,
            readingTime: ReadingTimeLog(
                file: persistence.readingTime, cloud: zone,
                legacyData: LegacyData(
                    legacy, lookupKey: ReadingTimeLog.cloudKey(profile: profile.cloudName))),
            themes: ThemeChoice(
                persistence: persistence.settings, cloud: zone,
                legacyData: LegacyData(
                    legacy, lookupKey: ThemeChoice.cloudKey(profile: profile.cloudName))),
            cloud: zone)
    }

    /// What moves to profile 1 on first launch with profiles from the old layout.
    public static var migrationPlan: ProfileMigration.Plan {
        let fm = FileManager.default
        let support =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return ProfileMigration.Plan(
            settings: settingsKey,
            moves: [
                .whole(old: caches.appending(path: "bestand"), to: .inventory),
                .whole(old: support.appending(path: "fortschritt"), to: .progress),
                .whole(old: support.appending(path: "lesezeit.json"), to: .readingTime),
                .files(
                    in: support,
                    startingWith: [Provider.opds.rawValue + "-", Provider.webdav.rawValue + "-"],
                    to: .states),
            ])
    }

    /// The UserDefaults keys that are per profile; the others (offline store cap,
    /// preloading, appearance, reader defaults) stay per device.
    public static let settingsKey: [String] = [
        SavedList.storeKey, ThemeChoice.storeKey, LanguageChoice.storeKey,
        LibraryService.bookSeriesKey, StartRow.lookupKey, Summary.automaticKey,
        AuthorHeader.wikipediaKey, PositionReporter.recordKey,
    ]
}

/// The active profile as an environment value, for everything a child profile hides
/// (import, sharing, sign-out, Wikipedia, clearing storage) and for the circle.
struct ProfileKey: EnvironmentKey {
    static let defaultValue = Profile(id: 0, name: "", color: ColorTheme.preset.rawValue)
}

/// The active profile's UserDefaults, for places that do not read via `@AppStorage`
/// (the `PositionReporter`). `nonisolated(unsafe)` because `UserDefaults` is not marked
/// `Sendable`, but according to Apple is safe from any thread.
struct ProfileSettingsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: UserDefaults = .standard
}

extension EnvironmentValues {
    var profile: Profile {
        get { self[ProfileKey.self] }
        set { self[ProfileKey.self] = newValue }
    }

    var profileSettings: UserDefaults {
        get { self[ProfileSettingsKey.self] }
        set { self[ProfileSettingsKey.self] = newValue }
    }
}

extension Profile {
    /// The circle's color: the theme name resolved; unknown values become the default.
    var theme: ColorTheme { ColorTheme(rawValue: color) ?? .preset }
}

extension ProfileContext {
    /// The profile's catalog as a file; if it cannot be opened (full, corrupt), a
    /// fresh one in memory, so the app stays usable and fills it on refresh.
    static func catalog(_ file: URL) -> CatalogIndex? {
        do {
            return try CatalogIndex(file: file)
        } catch {
            Diagnostics.network.error(
                "Catalog not opened: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: file)
            return try? CatalogIndex(file: file)
        }
    }
}
