import AccountsKit
import Bedrock
import DesignSystem
import Device
import Library
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import SwiftUI
import Testing

@testable import Features

/// A test rig for profiles in the shell: in-memory keychain, separate UserDefaults per run
/// and profile, folders under `tmp`, and a context that needs no server. Cleaned up at the end.
@MainActor
final class ProfileState {
    let store = InMemoryStore()
    let identifier = UUID().uuidString
    let root: URL
    let settings: UserDefaults
    let device: DeviceSource
    let profiles: ProfileRegistry

    init(migration: ProfileMigration.Plan = ProfileMigration.Plan()) {
        root = FileManager.default.temporaryDirectory.appending(path: "huelle-profile-\(identifier)")
        settings = UserDefaults(suiteName: "huelle-test-\(identifier)")!
        device = DeviceSource(folder: root.appending(path: "geraet"))
        let identifier = identifier
        profiles = ProfileRegistry(
            store: store, settings: settings, root: root,
            suites: { "huelle-test-\(identifier)-\($0)" }, deviceName: "Prüfstand", migration: migration)
    }

    func context(
        _ profile: Profile, _ persistence: ProfileStore, _ device: DeviceSource,
        sources: (@MainActor () -> [any Source])? = nil
    ) -> ProfileContext {
        let accounts = AccountRegistry(
            persistence: AccountStore(store: store, profile: persistence),
            trusts: CertificateTrustStore(store: store),
            factory: SourceFactory { _ in URLSession.shared }, questions: CertificateQuestion(),
            deviceName: "Prüfstand")
        let inventory = LibraryService(
            persistence: LibraryStore(folder: persistence.inventory),
            savedList: SavedList(persistence: persistence.settings, cloud: nil),
            settings: persistence.settings,
            queue: Queue(folder: nil), maxAge: profile.maxAge,
            sources: sources ?? { accounts.allSources })
        return ProfileContext(
            profile: profile, persistence: persistence, accounts: accounts, inventory: inventory,
            readingTime: ReadingTimeLog(file: nil),
            themes: ThemeChoice(persistence: persistence.settings, cloud: nil))
    }

    func tidyUp() {
        try? FileManager.default.removeItem(at: root)
        settings.removePersistentDomain(forName: "huelle-test-\(identifier)")
        for i in 1...5 {
            UserDefaults(suiteName: "huelle-test-\(identifier)-\(i)")?
                .removePersistentDomain(forName: "huelle-test-\(identifier)-\(i)")
        }
    }
}

/// Profiles in the shell: the migration plan, the context per profile, the child profile.
@Suite("Profiles in the shell")
@MainActor
struct ProfileTests {

    @Test("The migration plan names every profile-scoped key and every old folder")
    func plan() {
        let plan = ProfileContext.migrationPlan
        #expect(
            Set(plan.settings) == [
                "gemerkt", "app.theme", "app.language", "library.reihen", "start.unten", "text.automatisch",
                "autoren.wikipedia", "lesezeit.erfassen",
            ])
        #expect(plan.moves.count == 4)
        var targets: [ProfileMigration.Target] = []
        for move in plan.moves {
            switch move {
            case .whole(let old, let target):
                targets.append(target)
                #expect(["bestand", "fortschritt", "lesezeit.json"].contains(old.lastPathComponent))
            case .files(_, let starts, let target):
                targets.append(target)
                #expect(starts == ["opds-", "webdav-"])
            }
        }
        #expect(Set(targets) == [.inventory, .progress, .readingTime, .states])
    }

    @Test("A child profile's context filters the shelf; an adult's does not")
    func childProfile() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let child = try state.profiles.create(to: "Kim", color: "indigo", maxAge: 6)
        let sources = MockShelf.base()
        let kind = state.context(child, state.profiles.persistence(child), state.device) { sources }
        let adult = state.context(state.profiles.active, state.profiles.activeStore, state.device) {
            sources
        }
        await kind.inventory.refresh()
        await adult.inventory.refresh()
        #expect(kind.inventory.shelf.counter(.manga).title == 0, "the mock series is rated 12+")
        #expect(adult.inventory.shelf.counter(.manga).title == 3)
        #expect(kind.profile.kind)
        #expect(kind.profile.theme == .indigo)
    }

    @Test("Two profiles, two saved lists, two themes, from separate suites")
    func separated() throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let spouse = try state.profiles.create(to: "Sam", color: "pflaume")
        let ownerContext = state.context(state.profiles.active, state.profiles.activeStore, state.device)
        let spouseContext = state.context(spouse, state.profiles.persistence(spouse), state.device)
        let identifier = TitleID(
            source: SourceID(provider: .grimmory, server: "buecher.example"), id: "1")
        ownerContext.inventory.savedList.save(.title(identifier))
        ownerContext.themes.set(.terracotta)
        #expect(spouseContext.inventory.savedList.entries.isEmpty)
        #expect(spouseContext.themes.chosen == .ink)
        #expect(ownerContext.settings.string(forKey: ThemeChoice.storeKey) == "terrakotta")
        #expect(spouseContext.settings.string(forKey: ThemeChoice.storeKey) == nil)
        // A child profile is recognizable by its value; the hiding rules ask only that.
        #expect(!ProfileKey.defaultValue.kind)
    }

    @Test("A profile's color name resolves to the theme, unknown ones to the default")
    func color() {
        #expect(Profile(id: 1, name: "Alex", color: "pflaume").theme == .plum)
        #expect(Profile(id: 1, name: "Alex", color: "neonrosa").theme == ColorTheme.preset)
        #expect(Profile(id: 1, name: "Kim K.", color: "tinte").initial == "K")
        #expect(Profile(id: 1, name: "  ", color: "tinte").initial == "?")
    }
}
