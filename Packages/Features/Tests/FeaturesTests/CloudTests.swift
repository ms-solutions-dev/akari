import AccountsKit
import Bedrock
import CloudSync
import DesignSystem
import Device
import Foundation
import Library
import ReadingProgress
import SourcesKit
import Testing

@testable import Features

/// The cloud in the core: binding at launch, the context with its zone, "Add
/// device" as setup code, the acceptance as a state change in the
/// profile registry, the switch, removing together with the zone.
@Suite("Cloud in the core")
@MainActor
struct CloudCoreTests {

    let server = CloudMock()

    /// A core with a mock cloud: the contexts build their zone against the central service
    /// as in operation (`ProfileContext.standard`), but with an in-memory keychain
    /// and without a server.
    func core(_ state: ProfileState, user: String, device: String) -> AppCore {
        let hub = CloudHub(
            service: server.access(user, name: user.capitalized), file: nil,
            device: DeviceDescription(identifier: device, name: device, model: "iPhone"))
        let store = state.store
        return AppCore(
            profiles: state.profiles,
            context: { profile, persistence, device in
                ProfileContext.standard(
                    profile, persistence: persistence, device: device, hub: hub, store: store,
                    legacyStorage: StorageMock())
            }, device: state.device, preview: true, cloud: hub)
    }

    @Test("At launch the core binds the active profile's zone and records it on the profile")
    func bind() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let core = core(state, user: "alex", device: "iPhone")
        await core.bindCloud()
        let zone = try #require(state.profiles.active.cloud)
        #expect(zone.isProfile && !zone.shared)
        #expect(core.context.cloud?.zone == zone)
        // Saved list and theme travel through the zone.
        core.context.themes.set(.plum)
        core.context.inventory.savedList.save(
            .title(TitleID(source: SourceID(provider: .komga, server: "comics.example"), id: "1")))
        await core.context.cloud?.equalSince()
        let top = server.content(ZoneID(name: zone.name, owner: "alex"))
        #expect(top.contains { $0.type == SavedList.type })
        #expect(top.first { $0.name == ThemeChoice.recordName }?["wert"]?.text == "pflaume")
        #expect(top.contains { $0.type == CloudHub.deviceType && $0["name"]?.text == "iPhone" })
    }

    @Test("Add device: code with sharing, acceptance creates the shared profile and switches to it")
    func acceptance() async throws {
        let owner = ProfileState()
        defer { owner.tidyUp() }
        let ownerCore = core(owner, user: "alex", device: "iPhone")
        await ownerCore.bindCloud()
        let zone = try #require(owner.profiles.active.cloud)
        ownerCore.context.themes.set(.indigo)
        var changed = owner.profiles.active
        changed.color = ColorTheme.indigo.rawValue
        owner.profiles.change(changed)
        await ownerCore.bindCloud()
        let sharing = try await ownerCore.cloud.share(zone, title: "Alex")
        let code = ownerCore.context.accounts.setupCode(
            person: "Alex", color: ColorTheme.indigo.rawValue, sharing: sharing.url)
        #expect(code.sharing == sharing.url && code.color == "indigo")

        // The family iPad on a different Apple ID scans the code.
        let family = ProfileState()
        defer { family.tidyUp() }
        let ipad = core(family, user: "familie", device: "iPad")
        #expect(family.profiles.all.count == 1)
        // Both test rigs are named "Prüfstand", so the question appears; here: create new;
        // the device keeps its name.
        ipad.questions.decider = { _ in .new }
        let read = try #require(SetupCode(code.url))
        let profile = try #require(try await ipad.acceptSharing(read))
        #expect(family.profiles.all.count == 2)
        #expect(profile.shared && profile.sharedBy == "Alex" && profile.name == "Prüfstand")
        #expect(profile.color == "indigo" && profile.cloud?.owner == "alex")
        #expect(family.profiles.active.id == profile.id, "the new profile is active")
        #expect(ipad.context.profile.id == profile.id)
        await ipad.context.cloud?.equalSince()
        #expect(ipad.context.themes.chosen == .indigo, "the theme comes from the owner's zone")
        // The same code once more: no second profile.
        _ = try await ipad.acceptSharing(read)
        #expect(family.profiles.all.count == 2)

        // The owner sees the iPad in the device list and as a participant.
        await ownerCore.context.cloud?.equalSince()
        #expect(
            CloudHub.devices(in: try #require(ownerCore.context.cloud)).map(\.name).sorted() == [
                "iPad", "iPhone",
            ])
        #expect(try await ownerCore.cloud.sharing(zone)?.invited.map(\.identifier) == ["familie"])

        // Leaving: the profile disappears on the iPad, everything stays with the owner.
        try await ipad.removeProfile(profile)
        #expect(family.profiles.all.count == 1)
        #expect(try await ownerCore.cloud.sharing(zone)?.invited.isEmpty == true)
        #expect(!server.content(ZoneID(name: zone.name, owner: "alex")).isEmpty)
    }

    // MARK: Adopting an existing local profile

    /// A session from `tage` days ago, within the zone's window.
    func session(_ days: Int, name: String) -> ReadingSession {
        let end = Date().addingTimeInterval(-Double(days) * 86_400)
        return ReadingSession(
            identifier: TitleID(
                source: SourceID(provider: .komga, server: "comics.example"), id: name),
            kind: .manga, startTime: end - 900, end: end, readingTime: 900, name: name)
    }

    func saveTarget(_ id: String) -> SaveTarget {
        .title(TitleID(source: SourceID(provider: .komga, server: "comics.example"), id: id))
    }

    /// The owner "alex" with five sessions and a saved entry, who shares
    /// the zone, and the code for it.
    func owner(
        _ state: ProfileState
    ) async throws -> (core: AppCore, zone: ZoneID, code: SetupCode) {
        var ownerCore = state.profiles.active
        ownerCore.name = "Alex"
        ownerCore.color = ColorTheme.indigo.rawValue
        state.profiles.change(ownerCore)
        let core = core(state, user: "alex", device: "iPhone")
        await core.bindCloud()
        let zone = try #require(state.profiles.active.cloud)
        for i in 1...5 { core.context.readingTime.save(session(i, name: "besitzer-\(i)")) }
        core.context.inventory.savedList.save(saveTarget("besitzer-merk"))
        core.context.themes.set(.indigo)
        await core.context.cloud?.equalSince()
        let sharing = try await core.cloud.share(zone, title: "Alex")
        let code = core.context.accounts.setupCode(
            person: "Alex", color: ColorTheme.indigo.rawValue, sharing: sharing.url)
        return (core, zone, try #require(SetupCode(code.url)))
    }

    /// The family iPad with a local profile of that name: three sessions, two
    /// saved entries, its own theme, bound to its own private zone.
    func familyIpad(_ state: ProfileState, name: String) async throws -> AppCore {
        var local = state.profiles.active
        local.name = name
        state.profiles.change(local)
        let core = core(state, user: "familie", device: "iPad")
        await core.bindCloud()
        for i in 1...3 { core.context.readingTime.save(session(10 + i, name: "lokal-\(i)")) }
        core.context.inventory.savedList.save(saveTarget("lokal-merk-1"))
        core.context.inventory.savedList.save(saveTarget("lokal-merk-2"))
        core.context.themes.set(.terracotta)
        await core.context.cloud?.equalSince()
        return core
    }

    @Test(
        "Adopt: the local profile binds to the sharing, zone has 8 sessions and 3 saved entries, old zone gone"
    )
    func adopt() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let (ownerCore, zone, code) = try await owner(state)
        let family = ProfileState()
        defer { family.tidyUp() }
        // Case and whitespace do not matter: " alex " is "Alex".
        let ipad = try await familyIpad(family, name: " alex ")
        let local = family.profiles.active
        let oldZone = try #require(local.cloud)
        #expect(server.zoneList().contains { $0.name == oldZone.name && $0.owner == "familie" })
        var asked: [SharingQuestions.Occasion] = []
        ipad.questions.decider = { question in
            switch question {
            case .adoption(let fall):
                asked.append(fall)
                return .adopt
            case .deviceName(let suggestion):
                #expect(suggestion == "iPad")
                return .name(" Familien-iPad ")
            }
        }

        let profile = try #require(try await ipad.acceptSharing(code))
        #expect(asked.map(\.local.id) == [local.id] && asked.first?.ownerName == "Alex")
        #expect(family.profiles.all.count == 1, "no second profile")
        #expect(profile.id == local.id && profile.shared && profile.sharedBy == "Alex")
        #expect(profile.name == "Alex" && profile.color == "indigo", "the owner's name and color")
        #expect(profile.cloud == ZoneID(name: zone.name, owner: "alex"))
        #expect(family.profiles.active.id == local.id && ipad.context.profile.id == local.id)

        let top = server.content(ZoneID(name: zone.name, owner: "alex"))
        #expect(top.filter { $0.type == ReadingTimeLog.type }.count == 8)
        #expect(top.filter { $0.type == SavedList.type }.count == 3)
        #expect(
            top.first { $0.name == ThemeChoice.recordName }?["wert"]?.text == "indigo",
            "the zone wins for the theme")
        #expect(ipad.context.readingTime.sessions.count == 8)
        #expect(ipad.context.inventory.savedList.entries.count == 3)
        #expect(ipad.context.themes.chosen == .indigo)
        #expect(!server.zoneList().contains { $0.owner == "familie" }, "the old private zone is gone")

        // The owner sees all of it, including the device name once the iPad has carried it up.
        await ipad.context.cloud?.equalSince()
        await ownerCore.context.cloud?.equalSince()
        #expect(ownerCore.context.readingTime.sessions.count == 8)
        #expect(ownerCore.context.inventory.savedList.entries.count == 3)
        // The iPad is named as the reader named it when joining, and the owner sees
        // whom it belongs to (the record's creator is the participant's Apple ID).
        let devices = CloudHub.devices(in: try #require(ownerCore.context.cloud))
        #expect(devices.map(\.name).sorted() == ["Familien-iPad", "iPhone"])
        let ipadEntry = try #require(devices.first { $0.name == "Familien-iPad" })
        #expect(ipadEntry.named && ipadEntry.creator == "familie")
        #expect(
            CloudHub.devices(from: "familie", in: try #require(ownerCore.context.cloud)).map(\.name) == [
                "Familien-iPad"
            ])
    }

    @Test("Creating new leaves the local profile alone; without a same-named profile no question")
    func createNew() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let (_, zone, code) = try await owner(state)
        let family = ProfileState()
        defer { family.tidyUp() }
        let ipad = try await familyIpad(family, name: "Alex")
        let local = family.profiles.active
        var asked = 0
        ipad.questions.decider = { question in
            guard case .adoption = question else { return .cancel }
            asked += 1
            return .new
        }
        let new = try #require(try await ipad.acceptSharing(code))
        #expect(asked == 1)
        #expect(family.profiles.all.count == 2 && new.id != local.id && new.shared)
        let oldProfile = try #require(family.profiles.all.first { $0.id == local.id })
        #expect(!oldProfile.shared && oldProfile.cloud == local.cloud, "the old profile stays as it was")
        #expect(
            server.content(ZoneID(name: zone.name, owner: "alex")).filter {
                $0.type == ReadingTimeLog.type
            }.count == 5)

        // Another device without a same-named profile: no question.
        let spouse = ProfileState()
        defer { spouse.tidyUp() }
        let second = try await familyIpad(spouse, name: "Sam")
        second.questions.decider = { question in
            guard case .adoption = question else { return .cancel }
            asked += 1
            return .cancel
        }
        _ = try await second.acceptSharing(code)
        #expect(asked == 1 && spouse.profiles.all.count == 2)
    }

    @Test("Cancelling leaves the sharing again, nothing happened")
    func cancel() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let (ownerCore, zone, code) = try await owner(state)
        let family = ProfileState()
        defer { family.tidyUp() }
        let ipad = try await familyIpad(family, name: "Alex")
        ipad.questions.decider = { _ in .cancel }
        #expect(try await ipad.acceptSharing(code) == nil)
        #expect(family.profiles.all.count == 1 && !family.profiles.active.shared)
        #expect(try await ownerCore.cloud.sharing(zone)?.invited.isEmpty == true)
    }

    @Test("Switch off: zone gone on the server, data stays in the mirror; on: new zone with everything")
    func toggle() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let core = core(state, user: "alex", device: "iPhone")
        await core.bindCloud()
        let zone = try #require(state.profiles.active.cloud)
        core.context.themes.set(.terracotta)
        await core.context.cloud?.equalSince()
        #expect(server.zoneList().count == 1)
        try await core.switchCloud(false, for: state.profiles.active)
        #expect(server.zoneList().isEmpty && state.profiles.active.cloud == nil)
        #expect(core.context.cloud?.state == .withoutCloud)
        #expect(core.context.themes.chosen == .terracotta, "locally everything stays")
        try await core.switchCloud(true, for: state.profiles.active)
        await core.bindCloud()
        let newCloud = try #require(state.profiles.active.cloud)
        #expect(newCloud != zone)
        #expect(
            server.content(ZoneID(name: newCloud.name, owner: "alex")).contains {
                $0["wert"]?.text == "terrakotta"
            })
    }

    @Test("Removing a profile cleans up the zone on the server")
    func remove() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let core = core(state, user: "alex", device: "iPhone")
        let spouse = try state.profiles.create(to: "Sam", color: "pflaume")
        try state.profiles.switchTo(to: spouse)
        core.switchTo(to: spouse)
        await core.bindCloud()
        let spouseContext = try #require(state.profiles.all[1].cloud)
        try state.profiles.switchTo(to: state.profiles.all[0])
        core.switchTo(to: state.profiles.all[0])
        try await core.removeProfile(state.profiles.all[1])
        #expect(
            !server.zoneList().contains { $0.name == spouseContext.name } && state.profiles.all.count == 1)
    }
}
