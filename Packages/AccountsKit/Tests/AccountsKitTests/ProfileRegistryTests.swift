import Bedrock
import CloudSync
import Foundation
import GrimmoryKit
import KomgaKit
import OpdsKit
import SourcesKit
import Testing
import WebdavKit

@testable import AccountsKit

/// The profiles without keychain and without real UserDefaults — creating, switching
/// with PIN, prefix, removing, and the move from the old layout.
@Suite("Profilregister")
@MainActor
struct ProfileRegistryTests {

    /// A test bench: keychain in memory, own UserDefaults per run (and per profile), a
    /// folder under `tmp` — everything is cleaned up at the end.
    @MainActor
    final class Status {
        let store = InMemoryStore()
        let identifier = UUID().uuidString
        let root: URL
        let settings: UserDefaults
        var clock = Date(timeIntervalSince1970: 1_000_000)

        init() {
            root = FileManager.default.temporaryDirectory.appending(path: "profile-\(identifier)")
            settings = Status.fresh("profil-test-\(identifier)")
        }

        static func fresh(_ name: String) -> UserDefaults {
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            return d
        }

        /// A profile's suite — the run's identifier makes it fresh, without every access
        /// having to empty it.
        func suite(_ profile: Int) -> UserDefaults {
            UserDefaults(suiteName: "profil-test-\(identifier)-\(profile)")!
        }

        func register(
            deviceName: String = "Prüfstand", migration: ProfileMigration.Plan = ProfileMigration.Plan()
        ) -> ProfileRegistry {
            let identifier = identifier
            let stepClock = StepClock(self)
            return ProfileRegistry(
                store: store, settings: settings, root: root,
                suites: { "profil-test-\(identifier)-\($0)" }, deviceName: deviceName,
                migration: migration, clock: { stepClock.now() })
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            settings.removePersistentDomain(forName: "profil-test-\(identifier)")
            for i in 1...5 { suite(i).removePersistentDomain(forName: "profil-test-\(identifier)-\(i)") }
        }
    }

    /// The lockout's clock — `@Sendable`, hence via a box that points at the current value.
    final class StepClock: @unchecked Sendable {
        private let state: Status
        init(_ state: Status) { self.state = state }
        func now() -> Date { MainActor.assumeIsolated { state.clock } }
    }

    private static func komga(_ name: String) -> AccountEntry {
        AccountEntry(
            account: .komga(
                KomgaAccount(
                    server: URL(string: "https://comics.example")!, userId: "1", email: name,
                    apiKey: "k",
                    keyId: "k1", roles: [])),
            device: "Prüfstand")
    }

    private static func grimmory(_ name: String) -> AccountEntry {
        AccountEntry(
            account: .grimmory(
                GrimmoryAccount(
                    server: URL(string: "https://buecher.example")!, userId: 1, username: name,
                    displayName: nil, mayFetch: true,
                    access: GrimmoryAccess(token: "t", refreshToken: "r", flow: .distantFuture))),
            device: "Prüfstand")
    }

    @Test("An empty device gets profile 1 named after the device name — and it is active")
    func empty() {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register(deviceName: "Alex's iPad")
        #expect(r.all.count == 1)
        #expect(r.active.id == 1)
        #expect(r.active.name == "Alex's iPad")
        #expect(r.active.initial == "A")
        #expect(!r.active.kind)
        #expect(!r.active.protected)
        #expect(r.active.prefix == "profil.1.")
        // The list lives in the keychain: a second registry finds the same profile.
        #expect(state.register().all.map(\.id) == [1])
    }

    @Test("Creating counts up and does not become active; changing takes over name, color, age")
    func createProfile() throws {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register()
        let second = try r.create(to: " Sam ", color: "pflaume")
        let kim = try r.create(to: "Kim", color: "indigo", maxAge: 12)
        #expect(second.id == 2 && second.name == "Sam")
        #expect(kim.id == 3 && kim.kind && kim.maxAge == 12)
        #expect(r.active.id == 1, "whoever creates one for a child stays themselves")
        var changed = kim
        changed.name = "Kim Y."
        changed.maxAge = 16
        r.change(changed)
        #expect(r.all[2].name == "Kim Y." && r.all[2].maxAge == 16)
        #expect(r.all[2].color == "indigo")
        // Adults without PIN as soon as a child exists: both.
        #expect(r.adultsWithoutPin.map(\.id) == [1, 2])
        try r.setPin("1234", for: second)
        #expect(r.adultsWithoutPin.map(\.id) == [1])
    }

    @Test("Switching: no PIN is immediate, a PIN must be right — three failures lock for 30 seconds")
    func switchWithPin() throws {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register()
        let second = try r.create(to: "Sam", color: "pflaume", pin: "2468")
        let kim = try r.create(to: "Kim", color: "indigo", maxAge: 12)
        try r.switchTo(to: kim)
        #expect(r.active.id == kim.id)
        #expect(state.settings.integer(forKey: "profile.aktiv") == kim.id)

        #expect(throws: ProfileError.pinWrong(remaining: 2)) { try r.switchTo(to: second, pin: "0000") }
        #expect(throws: ProfileError.pinWrong(remaining: 1)) { try r.switchTo(to: second, pin: "1111") }
        let until = state.clock.addingTimeInterval(PinProtection.pause)
        #expect(throws: ProfileError.locked(until: until)) { try r.switchTo(to: second, pin: "2222") }
        // Even the right PIN does not help during the pause.
        #expect(throws: ProfileError.locked(until: until)) { try r.switchTo(to: second, pin: "2468") }
        #expect(r.lockedUntil(second) == until)
        #expect(r.active.id == kim.id)
        // After 30 seconds it works again — and the right attempt clears the count.
        state.clock = until.addingTimeInterval(1)
        #expect(r.lockedUntil(second) == nil)
        try r.switchTo(to: second, pin: "2468")
        #expect(r.active.id == second.id)
        // The active profile needs no PIN; a new registry reads the active one.
        try r.switchTo(to: second)
        #expect(state.register().active.id == second.id)
    }

    @Test("The lockout survives a new registry — closing and reopening the app does not help")
    func lockoutPersists() throws {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register()
        let second = try r.create(to: "Sam", color: "pflaume", pin: "2468")
        for pin in ["0000", "1111", "2222"] { _ = try? r.switchTo(to: second, pin: pin) }
        let new = state.register()
        #expect(new.lockedUntil(second) != nil)
    }

    @Test("PIN: four digits, salted, never plain text; removing it frees the profile")
    func pin() throws {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register()
        #expect(throws: ProfileError.pinInvalid) { try r.create(to: "X", color: "tinte", pin: "12") }
        #expect(throws: ProfileError.pinInvalid) { try r.create(to: "X", color: "tinte", pin: "abcd") }
        let second = try r.create(to: "Sam", color: "pflaume", pin: "2468")
        let entry = try state.store.value(for: "profil.2.pin")
        #expect(!entry.contains("2468"))
        #expect(entry.split(separator: ":").count == 2)
        #expect(PinProtection.matches("2468", to: entry))
        #expect(!PinProtection.matches("2469", to: entry))
        // Two mintings of the same PIN differ — the salt.
        #expect(PinProtection.mint("2468") != PinProtection.mint("2468"))
        try r.setPin(nil, for: second)
        #expect(!r.all[1].protected)
        #expect((try? state.store.value(for: "profil.2.pin")) == nil)
        try r.switchTo(to: second)
        #expect(r.active.id == second.id)
    }

    @Test("A profile's accounts live under its prefix — two profiles, two Komga accounts")
    func prefix() throws {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register()
        let second = try r.create(to: "Sam", color: "pflaume")
        let alex = AccountStore(store: state.store, profile: r.persistence(r.active))
        let secondStore = AccountStore(store: state.store, profile: r.persistence(second))
        try alex.persist(Self.komga("leser@example.test"), on: .server(.komga))
        try secondStore.persist(Self.komga("robin@example.test"), on: .server(.komga))
        try secondStore.persist(
            AccountEntry(
                account: .opds(
                    OpdsAccount(
                        catalog: URL(string: "https://kavita.example/opds")!, username: "", password: "",
                        title: "Kavita")),
                device: "Prüfstand"), on: AccountSlot(.opds, number: 0))
        #expect(alex.entry(.komga)?.account.username == "leser@example.test")
        #expect(secondStore.entry(.komga)?.account.username == "robin@example.test")
        #expect(alex.slots(.opds).isEmpty)
        #expect(secondStore.slots(.opds) == [AccountSlot(.opds, number: 0)])
        #expect((try? state.store.value(for: "profil.1.konto.komga")) != nil)
        #expect((try? state.store.value(for: "profil.2.konto.komga")) != nil)
        #expect((try? state.store.value(for: "profil.2.konto.opds.liste")) != nil)
        #expect((try? state.store.value(for: "konto.komga")) == nil, "nothing left without prefix")
        // The store: prefix, own suite, own folder.
        let persistence = r.persistence(second)
        #expect(persistence.prefix == "profil.2.")
        #expect(persistence.folder.lastPathComponent == "2")
        #expect(persistence.inventory.path.hasSuffix("/2/bestand"))
        #expect(persistence.readingTime.lastPathComponent == "lesezeit.json")
        persistence.settings.set("pflaume", forKey: "app.theme")
        #expect(r.persistence(r.active).settings.string(forKey: "app.theme") == nil)
    }

    @Test("Removing deletes the profile's accounts, PIN, suite and folder — the last one stays")
    func removeProfile() throws {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register()
        #expect(throws: ProfileError.lastProfile) { try r.remove(r.active) }
        let second = try r.create(to: "Sam", color: "pflaume", pin: "2468")
        let persistence = r.persistence(second)
        try AccountStore(store: state.store, profile: persistence).persist(
            Self.komga("robin@example.test"), on: .server(.komga))
        try FileManager.default.createDirectory(at: persistence.inventory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: persistence.inventory.appending(path: "komga@comics.example.json"))
        persistence.settings.set("pflaume", forKey: "app.theme")
        try r.switchTo(to: second, pin: "2468")

        try r.remove(second)
        #expect(r.all.map(\.id) == [1])
        #expect(r.active.id == 1, "if it was the active one, the first remaining one is active")
        #expect((try? state.store.value(for: "profil.2.konto.komga")) == nil)
        #expect((try? state.store.value(for: "profil.2.pin")) == nil)
        #expect(!FileManager.default.fileExists(atPath: persistence.folder.path))
        #expect(state.suite(2).string(forKey: "app.theme") == nil)
        // Number 2 is not reissued.
        #expect(try r.create(to: "Kim", color: "indigo").id == 3)
    }

    @Test("Renaming after the person from the code — only the single, untouched profile")
    func renameProfile() throws {
        let state = Status()
        defer { state.cleanUp() }
        let r = state.register(deviceName: "iPad")
        r.rename(to: "Alex", ifUntouched: false)
        #expect(r.active.name == "iPad", "with an account the name stays")
        r.rename(to: " Alex ", ifUntouched: true)
        #expect(r.active.name == "Alex")
        try r.create(to: "Sam", color: "pflaume")
        r.rename(to: "Kim", ifUntouched: true)
        #expect(r.active.name == "Alex", "with two profiles the code renames nothing anymore")
    }

    @Test(
        "Migration: keychain and folders in the old layout become profile 1 — name from the account, old keys gone"
    )
    func migration() throws {
        let state = Status()
        defer { state.cleanUp() }
        let fm = FileManager.default
        // The old layout: three servers, two OPDS catalogs with list, a WebDAV folder.
        let legacy = AccountStore(store: state.store)
        try legacy.persist(Self.komga("leser@example.test"), on: .server(.komga))
        try legacy.persist(Self.grimmory("leser"), on: .server(.grimmory))
        for (number, host) in [(0, "kavita.example"), (2, "comics2.example")] {
            try legacy.persist(
                AccountEntry(
                    account: .opds(
                        OpdsAccount(
                            catalog: URL(string: "https://\(host)/opds")!, username: "", password: "",
                            title: host)),
                    device: "Prüfstand"), on: AccountSlot(.opds, number: number))
        }
        try legacy.persist(
            AccountEntry(
                account: .webdav(
                    WebdavAccount(
                        folder: URL(string: "https://cloud.example/remote.php/dav/files/alex/Buecher/")!,
                        username: "alex", password: "p")),
                device: "Prüfstand"), on: AccountSlot(.webdav, number: 0))
        #expect((try? state.store.value(for: "konto.opds.liste")) != nil)
        // UserDefaults in the old layout.
        state.settings.set(Data("[]".utf8), forKey: "gemerkt")
        state.settings.set("pflaume", forKey: "app.theme")
        state.settings.set("neu", forKey: "start.unten")
        state.settings.set(true, forKey: "bleibt.geteilt")
        // Folders and files in the old layout.
        let legacyRoot = fm.temporaryDirectory.appending(path: "alt-\(state.identifier)")
        defer { try? fm.removeItem(at: legacyRoot) }
        let inventory = legacyRoot.appending(path: "bestand")
        let progress = legacyRoot.appending(path: "fortschritt")
        try fm.createDirectory(at: inventory, withIntermediateDirectories: true)
        try fm.createDirectory(at: progress, withIntermediateDirectories: true)
        try Data("auszug".utf8).write(to: inventory.appending(path: "komga@comics.example.json"))
        try Data("schlange".utf8).write(to: progress.appending(path: "schlange.json"))
        try Data("log".utf8).write(to: legacyRoot.appending(path: "lesezeit.json"))
        try Data("stand".utf8).write(to: legacyRoot.appending(path: "opds-kavita.example.json"))
        try Data("stand".utf8).write(to: legacyRoot.appending(path: "webdav-cloud.home_remote.php.json"))
        try Data("fremd".utf8).write(to: legacyRoot.appending(path: "anderes.json"))

        let plan = ProfileMigration.Plan(
            settings: ["gemerkt", "app.theme", "start.unten", "nicht.da"],
            moves: [
                .whole(old: inventory, to: .inventory), .whole(old: progress, to: .progress),
                .whole(old: legacyRoot.appending(path: "lesezeit.json"), to: .readingTime),
                .files(in: legacyRoot, startingWith: ["opds-", "webdav-"], to: .states),
                .whole(old: legacyRoot.appending(path: "gibt.es.nicht"), to: .inventory),
            ])
        let r = state.register(deviceName: "iPad", migration: plan)

        // Profile 1 is named after the account and sees everything.
        #expect(r.all.count == 1 && r.active.id == 1)
        #expect(r.active.name == "leser")
        let new = AccountStore(store: state.store, profile: r.persistence(r.active))
        #expect(new.entry(.komga)?.account.username == "leser@example.test")
        #expect(new.entry(.grimmory)?.account.username == "leser")
        #expect(new.slots(.opds) == [AccountSlot(.opds, number: 0), AccountSlot(.opds, number: 2)])
        #expect(new.entry(AccountSlot(.opds, number: 2))?.account.displayName == "comics2.example")
        #expect(new.slots(.webdav) == [AccountSlot(.webdav, number: 0)])
        #expect(new.all().count == 5)
        // The old keys are gone — moved, not copied.
        for lookupKey in [
            "konto.komga", "konto.grimmory", "konto.opds", "konto.opds.2", "konto.opds.liste", "konto.webdav",
            "konto.webdav.liste",
        ] {
            #expect((try? state.store.value(for: lookupKey)) == nil, Comment(rawValue: lookupKey))
        }
        #expect(AccountStore(store: state.store).all().isEmpty)
        // UserDefaults: in profile 1's suite, gone from the standard; shared stays.
        let suite = r.persistence(r.active).settings
        #expect(suite.data(forKey: "gemerkt") == Data("[]".utf8))
        #expect(suite.string(forKey: "app.theme") == "pflaume")
        #expect(suite.string(forKey: "start.unten") == "neu")
        #expect(state.settings.object(forKey: "gemerkt") == nil)
        #expect(state.settings.object(forKey: "app.theme") == nil)
        #expect(state.settings.bool(forKey: "bleibt.geteilt"))
        // Files: in the profile folder, no longer at the old location.
        let persistence = r.persistence(r.active)
        #expect(
            fm.fileExists(atPath: persistence.inventory.appending(path: "komga@comics.example.json").path))
        #expect(fm.fileExists(atPath: persistence.progress.appending(path: "schlange.json").path))
        #expect(fm.fileExists(atPath: persistence.readingTime.path))
        #expect(fm.fileExists(atPath: persistence.states.appending(path: "opds-kavita.example.json").path))
        #expect(
            fm.fileExists(
                atPath: persistence.states.appending(path: "webdav-cloud.home_remote.php.json").path))
        #expect(!fm.fileExists(atPath: inventory.path))
        #expect(!fm.fileExists(atPath: progress.path))
        #expect(!fm.fileExists(atPath: legacyRoot.appending(path: "lesezeit.json").path))
        #expect(!fm.fileExists(atPath: legacyRoot.appending(path: "opds-kavita.example.json").path))
        #expect(
            fm.fileExists(atPath: legacyRoot.appending(path: "anderes.json").path), "foreign files stay")
        // A second start does not migrate again.
        state.settings.set("tinte", forKey: "app.theme")
        let secondRegister = state.register(deviceName: "iPad", migration: plan)
        #expect(secondRegister.all.map(\.name) == ["leser"])
        #expect(suite.string(forKey: "app.theme") == "pflaume")
    }

    @Test("The setup code carries the person — and only if it carries one")
    func person() throws {
        let with = try #require(
            SetupCode(
                text:
                    "akari://einrichten?komga=https://comics.example&komga-name=leser@example.test&person=Alex"
            ))
        #expect(with.person == "Alex")
        #expect(with.url.query()?.contains("person=Alex") == true)
        let without = try #require(SetupCode(text: "akari://einrichten?komga=https://comics.example"))
        #expect(without.person == nil)
        #expect(without.url.query()?.contains("person") == false)
    }

    @Test("The zone hangs on the profile: binding, switch, accepted profile — and old lists stay readable")
    func cloud() throws {
        let state = Status()
        defer { state.cleanUp() }
        let register = state.register()
        let zone = ZoneID(profile: UUID())
        register.bind(register.active, to: zone)
        #expect(register.active.cloud == zone && !register.active.shared && register.active.cloudSync)
        #expect(state.register().active.cloud == zone, "the zone is in the list")
        register.setCloudSync(false, for: register.active)
        #expect(register.active.cloud == nil && !register.active.cloudSync)

        let foreign = ZoneID(name: zone.name, owner: "_alex")
        let shared = register.createShared(to: "Alex", color: "indigo", zone: foreign, from: "Alex Doe")
        #expect(shared.shared && shared.sharedBy == "Alex Doe" && shared.id == 2)
        #expect(
            register.createShared(to: "Alex", color: "indigo", zone: foreign, from: nil).id == 2,
            "not twice")
        register.setCloudSync(false, for: shared)
        #expect(register.all[1].cloud == foreign, "a foreign zone stays on the profile")

        let legacy = Data(
            """
            {"profile":[{"id":1,"name":"Alex","farbe":"tinte","geschuetzt":false,"angelegt":"2026-09-19T10:00:00Z"}],"naechste":2}
            """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(
            [String: [Profile]].self,
            from: Data("{\"profile\":[{\"id\":1,\"name\":\"Alex\",\"farbe\":\"tinte\"}]}".utf8))["profile"]?
            .first
        #expect(profile?.cloud == nil && profile?.cloudSync == true && profile?.protected == false)
        _ = legacy
    }
}
