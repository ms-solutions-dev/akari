import AccountsKit
import AudioPlayer
import AudiobookshelfKit
import Bedrock
import CloudSync
import DesignSystem
import Device
import Foundation
import GrimmoryKit
import KomgaKit
import Library
import Observation
import OfflineStore
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import SwiftUI
import WidgetBridge

#if canImport(UIKit)
    import UIKit
#endif

/// What the app has **once**, before any UI exists, and what the shell takes over when it
/// arrives: profiles and the context of the active profile, the player, the offline store,
/// the read call, the device source, the network meter and the writer of the listening
/// snapshot.
///
/// **Why it exists:** the play button of the "Continue listening" widget is an
/// `AudioPlaybackIntent` and runs in the app's process, even when the system starts the app
/// in the background for it, without a scene. Previously the shell held the player as
/// `@State` and assigned the `ContinueListeningSwitch` once its tabs stood; without a scene
/// there was no shell, no player, no switch, and the button did nothing. Now `AkariApp.init`
/// creates the core and assigns the switch before anything is drawn; the `AudiobookStarter`
/// loads and plays from the core, and when the shell arrives later it finds the running
/// player: mini player visible, state continues, nothing is loaded a second time.
///
/// **One player, one context.** What lives here the shell does not have again: it reads
/// `context` from here and swaps it on a profile switch via `switchTo(to:)`, so the starter
/// also sees the new profile. What only the UI needs (network watcher, notices, collection
/// question, the two other snapshot writers) stays in the shell.
///
/// **And the cloud:** the `CloudHub` lives here because a silent push wakes the app without
/// a scene; the app delegate hands it to `process(push:)`. After every context build the
/// core binds the profile's zone (`bindCloud()`); accepting a share from the setup code
/// creates the shared profile and switches to it (`acceptSharing(_:)`), or adopts a local
/// profile of the same name together with its data if the reader wants that, and asks once
/// for this device's name (`SharingQuestions`). Syncing does not run only on push:
/// `sameCloudSince()` runs when returning to the foreground and when opening Saved,
/// Statistics and "iCloud & Devices", throttled so a tab switch does not cause a trip to
/// the server.
@MainActor
@Observable
public final class AppCore {

    public let profiles: ProfileRegistry
    public private(set) var context: ProfileContext
    public let cloud: CloudHub
    /// The questions when accepting a share; the shell shows them.
    public let questions = SharingQuestions()
    /// When the last opportunistic sync ran (`sameCloudSince()`).
    private var lastSync: Date?
    /// Whoever delivers notifications: the system in operation, a mailbox in a test.
    public var sender: any NotificationSender = SystemSender()
    /// When the episode watcher last ran in the foreground (`checkEpisodesOccasionally()`).
    private var lastEpisodeWatcher: Date?
    /// A link the shell opens after the first frame as if it came from outside, for probes
    /// with mocks whose share link only comes into being when the core is built.
    public internal(set) var sampleLink: URL?
    let device: DeviceSource
    let player = Player()
    let stock = StockService()
    let reader = ReadCall()
    let metering = NetworkMeter()
    let listenSnapshot: ContinueListeningWriter
    /// Without welcome flow and without server check: mocks.
    let preview: Bool
    let makeContext: (Profile, ProfileStore, DeviceSource) -> ProfileContext
    /// The disruption probe with its stage, only with `-attrappen` and
    /// `AKARI_PROBE=stoerung:<case>`; the shell plays the schedule after the first frame.
    var disruption: (probe: DisruptionProbe, sources: [MockSource], transport: MockTransport)?

    /// - Parameter profiles: The profile registry: in operation the one with the keychain
    ///   (and the migration to profile 1), in a test one with mocks.
    /// - Parameter context: Builds the context of a profile; in operation
    ///   `ProfileContext.standard(_:persistence:device:hub:store:)`, in a test one with mocks;
    ///   called again on a switch.
    /// - Parameter listenSnapshot: The writer of the listening snapshot: in operation the
    ///   one into the app group, in a test one into a folder under `tmp`.
    /// - Parameter cloud: The hub: in operation with the CloudKit service, in a test with
    ///   the mock or without a service.
    init(
        profiles: ProfileRegistry, context: @escaping (Profile, ProfileStore, DeviceSource) -> ProfileContext,
        device: DeviceSource, preview: Bool,
        listenSnapshot: ContinueListeningWriter = ContinueListeningWriter(),
        cloud: CloudHub = CloudHub(service: nil, file: nil, device: AppCore.thisDevice)
    ) {
        self.profiles = profiles
        self.device = device
        self.cloud = cloud
        self.context = context(profiles.active, profiles.persistence(profiles.active), device)
        self.makeContext = context
        self.preview = preview
        self.listenSnapshot = listenSnapshot
        Task { await startCloud() }
    }

    /// The core in operation: keychain, profile folder, device source, CloudKit.
    public static func standard() -> AppCore {
        let hub = CloudHub(
            service: CloudKitService(
                container: "iCloud.dev.ms-solutions.akari",
                subscriptionPrefix: "akari",
                // Without a set environment the environment watcher stays off, and Akari
                // runs as before.
                environment: nil),
            file: CloudHub.defaultFileName, device: thisDevice)
        return AppCore(
            profiles: ProfileRegistry(migration: ProfileContext.migrationPlan),
            context: { ProfileContext.standard($0, persistence: $1, device: $2, hub: hub) },
            device: DeviceSource(), preview: false, cloud: hub)
    }

    /// This device for the `Device` record in the zone: name, model, one identifier per
    /// installation (`Bedrock.DeviceIdentity`).
    static var thisDevice: DeviceDescription {
        #if canImport(UIKit)
            let model = UIDevice.current.model
        #else
            let model = "Mac"
        #endif
        return DeviceDescription(identifier: DeviceIdentity.id(), name: DeviceName.thisDevice, model: model)
    }

    /// Another profile (or a renamed one; the zone gets the new name): player off, context
    /// new. The shell sets the profile's language.
    func switchTo(to new: Profile) {
        guard
            new.id != context.profile.id || new.name != context.profile.name
                || new.cloudSync != context.profile.cloudSync
        else { return }
        player.close()
        reader.ongoing = nil
        reader.title = nil
        context = makeContext(new, profiles.persistence(new), device)
        Task { await bindCloud() }
    }

    // MARK: - Cloud

    /// Once at launch: account, subscriptions, a look into both databases, then the active
    /// profile's zone.
    func startCloud() async {
        await cloud.launch()
        await bindCloud()
    }

    /// Binds the active profile's zone (or syncs the bound one) and records the identifier
    /// on the profile. Without an account everything stays local.
    public func bindCloud() async {
        let profile = profiles.all.first { $0.id == context.profile.id } ?? context.profile
        guard let zone = context.cloud, profile.cloudSync else { return }
        let identifier = await cloud.bind(zone, identifier: UUID(), name: profile.name, color: profile.color)
        if let identifier, profile.cloud != identifier { profiles.bind(profile, to: identifier) }
    }

    /// A silent push from CloudKit: `true` if it was one.
    public func process(push: [AnyHashable: Any]) async -> Bool {
        await cloud.process(push: push)
    }

    /// How long an opportunistic sync blocks the next.
    static let syncInterval: TimeInterval = 30

    /// The sync on occasion: returning to the foreground, opening Saved, reading statistics
    /// or "iCloud & Devices". A silent push does not always arrive (a save from the other
    /// device appeared only after a manual sync). At most every 30 seconds; "Sync now" in
    /// the sheet bypasses that.
    public func sameCloudSince() {
        guard let zone = context.cloud, zone.zone != nil, cloud.account == .available else { return }
        if let lastSync, Date().timeIntervalSince(lastSync) < AppCore.syncInterval { return }
        lastSync = Date()
        Task { await zone.equalSince() }
    }

    /// The episode watcher for the active profile: fetch and report new episodes of
    /// subscribed podcasts. The background fetch calls this directly; a child profile
    /// reports nothing, and without the system's permission the watcher does not even ask.
    ///
    /// **Only the active profile:** on a family iPad whoever read last gets notified.
    /// Building every profile in the background would mean loading its accounts and zone,
    /// for a notification whose link points nowhere in the wrong profile.
    public func checkEpisodes() async {
        guard !context.profile.kind, context.notifications.to, await sender.allowed() else { return }
        let messages = await EpisodeWatcher.check(
            source: context.inventory.source, choice: context.notifications)
        await sender.spot(messages)
    }

    /// On returning to the foreground, at most every 15 minutes, because iOS grants the
    /// background fetch as it likes and the return to the app is the one reliable moment.
    public func checkEpisodesOccasionally() {
        if let lastEpisodeWatcher, Date().timeIntervalSince(lastEpisodeWatcher) < AppCore.episodeWatchInterval
        {
            return
        }
        lastEpisodeWatcher = Date()
        Task { await checkEpisodes() }
    }

    static let episodeWatchInterval: TimeInterval = 15 * 60

    /// A link from outside the scene, the tap on a notification: the shell opens it like a
    /// link from the widget once it stands.
    public func open(link: URL) {
        sampleLink = link
    }

    /// "Add device" on the new device: accept the share, create the profile (name and color
    /// from the owner, or from the code), switch to it, suggest the code's accounts. The
    /// passwords are asked by the welcome flow.
    ///
    /// **If a local profile of the same name already exists here** (not shared, name after
    /// `CloudHub.normalized(_:)`), the core asks via `questions`: "Adopt" rebinds this
    /// profile to the owner's zone and merges its data there (`adopt(_:with:name:color:code:)`),
    /// "Create new" puts a second one beside it as before, Cancel leaves the share just
    /// accepted again, so nothing has happened and the answer is `nil`. The acceptance
    /// precedes the question because only the zone says what the profile is called at the
    /// owner.
    public func acceptSharing(_ code: SetupCode) async throws(CloudError) -> Profile? {
        guard let sharing = code.sharing else {
            throw .rejected(
                String(localized: "cloud.error.noShareLink", defaultValue: "No share link", bundle: .main))
        }
        let accepted = try await cloud.accept(url: sharing)
        let name = accepted.profileName ?? code.person ?? accepted.ownerName ?? "iCloud"
        let color = accepted.color ?? code.color ?? ColorTheme.preset.rawValue
        if !profiles.all.contains(where: { $0.cloud == accepted.zone }),
            let local = profiles.matchingLocal(to: name)
        {
            switch await questions.question(
                .adoption(SharingQuestions.Occasion(local: local, ownerName: accepted.ownerName)))
            {
            case .adopt:
                let profile = try await adopt(local, with: accepted, name: name, color: color, code: code)
                await nameThisDevice()
                return profile
            case .new, .name: break
            case .cancel:
                try? await cloud.leave(accepted.zone)
                return nil
            }
        }
        let profile = profiles.createShared(
            to: name, color: color, zone: accepted.zone, from: accepted.ownerName)
        try? profiles.switchTo(to: profile)
        switchTo(to: profile)
        context.accounts.adopt(code)
        await nameThisDevice()
        return profile
    }

    /// "What should this device be called?": once on joining, prefilled with the system
    /// name; the answer is stored as `Device` in the owner's zone, and
    /// `CloudHub.writeDevice(in:)` never resets it.
    private func nameThisDevice() async {
        guard let zone = context.cloud else { return }
        let suggestion = cloud.device.name
        let name: String
        switch await questions.question(.deviceName(suggestion: suggestion)) {
        case .name(let input):
            let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
            name = cleaned.isEmpty ? suggestion : cleaned
        case .adopt, .new, .cancel: name = suggestion
        }
        cloud.renameDevice(cloud.device.identifier, name: name, in: zone)
    }

    /// A local profile adopts the share, so nothing is lost:
    ///
    /// 1. The profile becomes active (without PIN, see `ProfileRegistry.activateForAdoption(_:)`)
    ///    and gets its context with the zone it had before: its own private one, or none.
    /// 2. This zone's mirror discards its `ProfileSetting` records (name, color, theme: the
    ///    owner's apply) and binds to the owner's zone (`ProfileZone.bind(to:)`): all
    ///    sessions and saved entries go up as write requests and merge there by identifier;
    ///    the same session on both sides is the same record, the later end wins.
    /// 3. The registry records the zone, then the trip to the server; reading time, saved
    ///    list and theme learn the result by observing the zone.
    /// 4. Only after the successful trip is the old private zone dropped at the server (the
    ///    device is its owner). If the trip fails, the queue stays and retries next time;
    ///    the old zone then stays, and the gap is noted in the log.
    /// 5. Name and color of the owner and the code's accounts as a suggestion next to the
    ///    reader's own; the passwords are asked by the welcome flow.
    private func adopt(
        _ local: Profile, with accepted: Accepted, name: String, color: String, code: SetupCode
    ) async throws(CloudError) -> Profile {
        profiles.activateForAdoption(local)
        if !local.cloudSync { profiles.setCloudSync(true, for: local) }
        guard let current = profiles.all.first(where: { $0.id == local.id }) else {
            throw .rejected(
                String(localized: "cloud.error.profileGone", defaultValue: "Profile gone", bundle: .main))
        }
        switchTo(to: current)
        guard let zone = context.cloud else { throw .noAccount }
        let old = zone.zone
        zone.discard(type: CloudHub.settingType)
        zone.bind(to: accepted.zone)
        zone.sharedBy = accepted.ownerName
        var profile = profiles.adoptSharing(current, zone: accepted.zone, from: accepted.ownerName)
        cloud.writeDevice(in: zone)
        await zone.equalSince()
        if case .synced = zone.state, zone.pending == 0 {
            if let old, !old.shared {
                do throws(CloudError) {
                    try await cloud.erase(old)
                } catch {
                    Diagnostics.deficiency(
                        "Cloud: old zone \(old.name) not deleted after adoption: \(error)",
                        since: nil,
                        area: "Cloud")
                }
            }
            Diagnostics.step(
                "Cloud: profile \"\(local.name)\" adopted the share from \(accepted.ownerName ?? "?")",
                since: nil, area: "Cloud")
        } else {
            Diagnostics.deficiency(
                "Cloud: adoption of \"\(local.name)\" not yet at the server: \(zone.state)", since: nil,
                area: "Cloud")
        }
        profile.name = name
        profile.color = color
        profiles.change(profile)
        if let new = profiles.all.first(where: { $0.id == profile.id }) { switchTo(to: new) }
        context.accounts.adopt(code)
        return profiles.active
    }

    /// The "Sync via iCloud" switch: on binds the zone; off deletes the zone at the server
    /// (own) and continues the profile without a zone, the data stays in the mirror. Then a
    /// new context, because the carrier changes.
    public func switchCloud(_ to: Bool, for profile: Profile) async throws(CloudError) {
        if !to, let zone = profile.cloud, !zone.shared {
            try await cloud.erase(zone)
            if profile.id == context.profile.id { context.cloud?.unbind() }
        }
        profiles.setCloudSync(to, for: profile)
        if let new = profiles.all.first(where: { $0.id == profile.id }), new.id == context.profile.id {
            switchTo(to: new)
        }
    }

    /// Remove a profile, together with its zone (owner) or share (participant). The zone goes
    /// first: if the server stays silent, the profile stays, and the error shows in the sheet.
    public func removeProfile(_ profile: Profile) async throws(CloudError) {
        if let zone = profile.cloud {
            if zone.shared { try await cloud.leave(zone) } else { try await cloud.erase(zone) }
        }
        do throws(ProfileError) {
            try profiles.remove(profile)
        } catch {
            throw .rejected(String(describing: error))
        }
    }

    /// The transport per provider: the account's session; for the device the `FileTransport`.
    nonisolated static func transport(_ provider: Provider, _ accounts: AccountRegistry) -> any Transport {
        provider == .device ? FileTransport() : accounts.transport(provider)
    }

    /// The transport for covers, pages, files and tracks, metered (`NetworkMeter`) so the
    /// status banner can say "Slow connection" before anyone waits 19 s for a page. The
    /// device does not meter: a file from disk says nothing about the line.
    ///
    /// Created once per accounts registry and remembered: the shell puts it into the
    /// environment, and a closure that is new on every access counted as changed for
    /// SwiftUI each time, so every cover recomputed on every re-evaluation of the shell.
    var imageTransport: @Sendable (Provider) -> any Transport {
        let accounts = context.accounts
        if let saved = imageTransportSaved, saved.accounts === accounts { return saved.call }
        let report = metering.report
        let call: @Sendable (Provider) -> any Transport = { provider in
            let transport = AppCore.transport(provider, accounts)
            return provider == .device ? transport : MeteringTransport(transport, report: report)
        }
        imageTransportSaved = (accounts, call)
        return call
    }

    @ObservationIgnored private var imageTransportSaved:
        (accounts: AccountRegistry, call: @Sendable (Provider) -> any Transport)?

    /// Headers and transport per source, for the widgets' covers.
    var sourceAccess: SnapshotWriter.SourceAccess {
        let accounts = context.accounts
        let inventory = context.inventory
        return SnapshotWriter.SourceAccess(
            headerLines: { inventory.headerLines($0) },
            transport: { AppCore.transport($0, accounts) })
    }

    /// The starter for the active profile, with the device's scale, because there is no
    /// window here that would have one.
    var audiobookStarter: AudiobookStarter {
        #if canImport(UIKit)
            let displayScale = UITraitCollection.current.displayScale
        #else
            let displayScale: CGFloat = 2
        #endif
        return AudiobookStarter(
            player: player, stock: stock, reader: reader, inventory: context.inventory,
            readingTime: context.readingTime,
            settings: context.settings, transport: imageTransport,
            coverEdge: AudiobookStarter.coverEdge(displayScale: displayScale))
    }

    /// The job for the listening snapshot from the current state.
    var listenJob: ContinueListeningWriter.Job {
        ContinueListeningWriter.Job.from(
            player, ongoing: reader.ongoing, shelf: context.inventory.shelf, profile: context.profile.name,
            multipleProfiles: profiles.all.count > 1)
    }

    /// The widget button: toggle or load and play (`AudiobookStarter.switchTo(identifier:link:)`),
    /// then write the snapshot **immediately**; the widget reloads right after the intent
    /// and should find the new state. It is also written after a failure, so the button does
    /// not show "Pause" where nothing plays.
    public func switchContinueListening(identifier: String, link: URL) async -> Bool {
        let done = await audiobookStarter.switchTo(identifier: identifier, link: link)
        listenSnapshot.schedule(listenJob, sources: sourceAccess)
        await listenSnapshot.immediately()
        return done
    }

    /// Assigns the slot of the play/pause intent, once, at app launch.
    public func assignContinueListeningSwitch() {
        ContinueListeningSwitch.switchTo = { [self] identifier, link in
            await switchContinueListening(identifier: identifier, link: link)
        }
    }
}

// MARK: - Mocks

extension AppCore {

    /// A file of the mock content (`MockContent/<name>.<ext>`), `nil` if it is not bundled.
    private static func mockContent(_ name: String, ext: String = "epub") -> Data? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "MockContent")
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// The core with the three mocks: no server, no keychain, covers stay placeholders.
    /// Launch argument `-attrappen`, so a screenshot in the simulator does not hang on a
    /// password.
    public static func mocks() -> AppCore {
        let store = InMemoryStore()
        // The preview transport knows one answer: every page of a volume is the same drawn
        // page, so the comic reader shows something in a screenshot instead of "Page not
        // loaded".
        let transport = MockTransport()
        transport.answer("GET", "/api/v1/books/*", with: .init(data: MockPage.jpeg()))
        let sources = MockShelf.all()
        // The sample covers: every cover address of the mocks is a bundled file
        // (`SampleCovers/<slug>.jpg`, public domain or CC BY), answered under `/covers/<slug>.jpg`.
        let coverAddresses =
            sources.flatMap(\.extract.title).compactMap(\.cover)
            + sources.flatMap(\.extract.seriesList).compactMap(\.cover)
        for slug in Set(coverAddresses.map { $0.deletingPathExtension().lastPathComponent }) {
            guard
                let file = Bundle.module.url(
                    forResource: slug, withExtension: "jpg", subdirectory: "SampleCovers"),
                let data = try? Data(contentsOf: file)
            else { continue }
            transport.answer(
                "GET", "/covers/\(slug).jpg",
                with: .init(data: data, headerLines: ["Content-Type": "image/jpeg"]))
        }
        // Every book is the same built EPUB (three chapters, one footnote), except the two
        // Holmes volumes: they carry a real public-domain story with a glossary
        // (`MockContent/`, written by the maintainer's `mockinhalte.py`).
        let epub = MockBook.epub(glossary: true)
        let stories = ["1041": "holmes-adventures", "1042": "holmes-memoirs"]
        for book in sources.flatMap(\.extract.title) where book.kind == .book {
            let story = stories[book.identifier.id].flatMap { mockContent($0) }
            transport.answer(
                "GET", "/api/v1/books/\(book.identifier.id)/content", with: .init(data: story ?? epub))
        }
        // Every comic page is one of eight real Pepper&Carrot pages (CC BY 4.0), cycling:
        // page n shows file ((n − 1) mod 8) + 1. Without the files the drawn page stays.
        let pages = (1...8).compactMap { mockContent("pepper-\($0)", ext: "jpg") }
        if pages.count == 8 {
            for volume in sources.flatMap(\.extract.title) where volume.kind == .manga {
                guard case .pages(let count) = volume.scope else { continue }
                for page in 1...max(count, 1) {
                    transport.answer(
                        "GET", "/api/v1/books/\(volume.identifier.id)/pages/\(page)",
                        with: .init(data: pages[(page - 1) % 8], headerLines: ["Content-Type": "image/jpeg"]))
                }
            }
        }
        // Every audiobook is one minute of reading (LibriVox, public domain), otherwise of
        // sound: three tones, three chapters.
        if let reading = mockContent("time-machine", ext: "m4a") {
            transport.answer(
                "GET", "/api/items/*", with: .init(data: reading, headerLines: ["Content-Type": "audio/mp4"]))
        } else {
            transport.answer(
                "GET", "/api/items/*",
                with: .init(data: MockSound.wav(), headerLines: ["Content-Type": "audio/wav"]))
        }
        // Grimmory keeps the saved list itself: the "server" must know the book, otherwise
        // the sync removes it again on refresh.
        sources[1].saved = [sources[1].extract.title[2].identifier]
        let device = DeviceSource(
            folder: FileManager.default.temporaryDirectory.appending(path: "attrappen-geraet"))
        // Three profiles: an owner with PIN 1234, a second adult, and a child up to 12, all
        // in memory and under `tmp` so the preview does not touch the real ones. For
        // `AKARI_PROBE=pin` the second profile is active, so the sheet asks for the owner's
        // PIN; for `AKARI_PROBE=kind` the child, so Start and the sheet show the child profile.
        let tmp = FileManager.default.temporaryDirectory
        let probe = ProcessInfo.processInfo.environment["AKARI_PROBE"]
        let transportForSources: any Transport =
            probe == "hoerbuch-behalten"
            ? ThrottledTransport(inner: transport, delay: .milliseconds(50)) : transport
        let profiles = ProfileRegistry(
            store: store, settings: UserDefaults(suiteName: "attrappen") ?? .standard,
            root: tmp.appending(path: "attrappen-profile"), suites: { "attrappen-profil-\($0)" },
            deviceName: "Alex")
        if profiles.all.count == 1 {
            try? profiles.setPin("1234", for: profiles.active)
            _ = try? profiles.create(to: "Sam", color: ColorTheme.plum.rawValue)
            _ = try? profiles.create(to: "Kim", color: ColorTheme.terracotta.rawValue, maxAge: 12)
        }
        switch probe {
        case "pin": try? profiles.switchTo(to: profiles.all[1])
        case "kind": try? profiles.switchTo(to: profiles.all[2])
        default: try? profiles.switchTo(to: profiles.all[0], pin: "1234")
        }
        // The disruption probe: its own mailbox for the certificate question so it can put
        // one in; the mocks fail before the shell asks.
        let questions = CertificateQuestion()
        let disruption = DisruptionProbe.present
        // The cloud stays in the process: an in-memory CloudKit so "iCloud & Devices" and
        // "Add device" show something in a screenshot without touching an account. For
        // `AKARI_PROBE=freigabe-uebernehmen` this device is the family iPad on the account
        // "familie", and the owner already shares their profile there, so the question comes.
        // `freigabe-geraetename` shares a profile with no local counterpart, so the device
        // name question comes right away.
        let server = CloudMock()
        let takeoverProbe = probe == "freigabe-uebernehmen" || probe == "freigabe-geraetename"
        let hub = CloudHub(
            service: server.access(takeoverProbe ? "familie" : "vorschau", name: "Vorschau"), file: nil,
            device: DeviceDescription(identifier: "vorschau", name: "Vorschau-iPhone", model: "iPhone"))
        let core = AppCore(
            profiles: profiles,
            context: { profile, persistence, device in
                let context = AppCore.mockContext(
                    profile, persistence: persistence, device: device, store: store,
                    transport: transportForSources,
                    sources: sources, questions: questions, hub: hub)
                disruption?.configure(
                    sources: sources, transport: transport, questions: questions,
                    persistence: LibraryStore(folder: persistence.inventory))
                return context
            }, device: device, preview: true, cloud: hub)
        core.disruption = disruption.map { ($0, sources, transport) }
        if takeoverProbe {
            AppCore.sharingProbe(
                server, sources: sources, person: probe == "freigabe-geraetename" ? "Jo" : "Alex",
                for: core)
        }
        return core
    }

    /// The stage of the adoption probe: the owner has a profile zone on the server with five
    /// sessions, one saved entry and the indigo theme, and shares it. The setup code for it
    /// becomes the `sampleLink` that the family iPad "scans": there a local profile of the
    /// same name already exists, so the question comes.
    private static func sharingProbe(
        _ server: CloudMock, sources: [MockSource], person: String, for core: AppCore
    ) {
        let ownerHub = CloudHub(
            service: server.access("alex", name: "Alex"), file: nil,
            device: DeviceDescription(identifier: "alexs-iphone", name: "Alex's iPhone", model: "iPhone"))
        let zone = ProfileZone(file: nil, service: ownerHub.service, unprompted: false)
        let readingTime = ReadingTimeLog(file: nil, cloud: zone)
        let book = sources[1].extract.title[0]
        for tag in 1...5 {
            let end = Date().addingTimeInterval(-Double(tag) * 86_400)
            readingTime.save(
                ReadingSession(
                    identifier: book.identifier, kind: .book, startTime: end - 1800, end: end,
                    readingTime: 1800,
                    fraction: 0.05, name: book.name))
        }
        let persistence = UserDefaults(suiteName: "attrappen-alex") ?? .standard
        SavedList(persistence: persistence, cloud: zone).save(.title(sources[1].extract.title[1].identifier))
        ThemeChoice(persistence: persistence, cloud: zone).set(.indigo)
        Task {
            guard
                let identifier = await ownerHub.bind(zone, identifier: UUID(), name: person, color: "indigo"),
                let sharing = try? await ownerHub.share(identifier, title: person).url
            else { return }
            core.sampleLink =
                SetupCode(server: [:], person: person, sharing: sharing, color: "indigo").url
        }
    }

    /// The context of a mock profile: an in-memory registry with three accounts whose
    /// "servers" are the mocks (so the registry checks the accounts as in operation and the
    /// banner says "Manga: unreachable"), the library from the registry, a saved list with
    /// two entries, two weeks of reading time, with separate files under `tmp` per profile
    /// so the switch has something to swap.
    private static func mockContext(
        _ profile: Profile, persistence: ProfileStore, device: DeviceSource, store: InMemoryStore,
        transport: any Transport, sources: [MockSource], questions: CertificateQuestion,
        hub: CloudHub
    ) -> ProfileContext {
        let accountStore = AccountStore(store: store, profile: persistence)
        for source in sources where accountStore.entry(.server(source.identifier.provider)) == nil {
            try? accountStore.persist(
                AccountEntry(account: AppCore.mockAccount(source), device: "Vorschau"),
                on: .server(source.identifier.provider))
        }
        let accounts = AccountRegistry(
            persistence: accountStore,
            trusts: CertificateTrustStore(store: store),
            factory: SourceFactory(own: { account in sources.first { $0.identifier == account.identifier } })
            {
                _ in transport
            }, questions: questions,
            deviceName: "Vorschau")
        // The preview's zone: in memory, against the hub's mock.
        let zone = ProfileZone(
            file: nil, service: profile.cloudSync ? hub.service : nil, zone: profile.cloud)
        zone.sharedBy = profile.sharedBy
        hub.register(zone)
        // A separate saved list so the preview does not touch the real one, and two entries
        // so the row on Start is visible.
        let savedList = SavedList(persistence: persistence.settings, cloud: zone)
        if savedList.entries.isEmpty {
            savedList.save(.title(sources[1].extract.title[2].identifier))
            savedList.save(.series(sources[0].extract.seriesList[0].identifier))
        }
        // Two weeks of reading sessions for the statistics sheet, in a separate file so the
        // preview does not touch the real log.
        let readingTime = ReadingTimeLog(file: persistence.readingTime, cloud: zone)
        if readingTime.sessions.isEmpty {
            let manga = sources[0].extract.title[1]
            let book = sources[1].extract.title[1]
            let audiobook = sources[2].extract.title[0]
            for tag in 0..<14 where tag % 4 != 3 {
                let end = Calendar.current.date(byAdding: .day, value: -tag, to: Date())!.addingTimeInterval(
                    -3600)
                readingTime.save(
                    ReadingSession(
                        identifier: manga.identifier, kind: .manga, startTime: end - 1500, end: end,
                        readingTime: 1500,
                        pages: 40, fraction: 0.2, name: "Pepper&Carrot · Volume 37"))
                if tag % 2 == 0 {
                    readingTime.save(
                        ReadingSession(
                            identifier: book.identifier, kind: .book, startTime: end - 2400 - 3600,
                            end: end - 3600,
                            readingTime: 2400, fraction: 0.06, completed: tag == 6, name: book.name))
                }
                if tag % 3 == 0 {
                    readingTime.save(
                        ReadingSession(
                            identifier: audiobook.identifier, kind: .audiobook, startTime: end - 9000,
                            end: end - 5400,
                            readingTime: 3600, fraction: 0.1, name: audiobook.name))
                }
            }
            let continued = TitleID(
                source: SourceID(provider: .komga, server: "alt.example"), id: "weg")
            readingTime.save(
                ReadingSession(
                    identifier: continued, kind: .manga, startTime: Date() - 9 * 86_400 - 900,
                    end: Date() - 9 * 86_400,
                    readingTime: 900, pages: 22, fraction: 0.1, name: "Little Nemo · Volume 3"))
        }
        let inventory = LibraryService(
            persistence: LibraryStore(folder: persistence.inventory), savedList: savedList,
            settings: persistence.settings, queue: Queue(folder: nil),
            maxAge: profile.maxAge
        ) { accounts.allSources + [device] }
        return ProfileContext(
            profile: profile, persistence: persistence, accounts: accounts, inventory: inventory,
            readingTime: readingTime,
            themes: ThemeChoice(persistence: persistence.settings, cloud: zone), cloud: zone)
    }

    /// An account for the mock: address and name match the identifier, the key is made up;
    /// the registry asks the mock anyway.
    private static func mockAccount(_ source: MockSource) -> Account {
        let server = URL(string: "https://\(source.identifier.server)")!
        switch source.identifier.provider {
        case .grimmory:
            return .grimmory(
                GrimmoryAccount(
                    server: server, userId: 2, username: "robin", displayName: nil, mayFetch: false,
                    access: GrimmoryAccess(
                        token: "attrappe", refreshToken: "attrappe", flow: .distantFuture)))
        case .audiobookshelf:
            return .audiobookshelf(
                AudiobookshelfAccount(
                    server: server, userId: "usr_attrappe", username: "leser", token: "attrappe",
                    mayFetch: true))
        default:
            return .komga(
                KomgaAccount(
                    server: server, userId: "0K7Q", email: "leser@comics.example", apiKey: "attrappe",
                    keyId: "attrappe", roles: ["USER", "PAGE_STREAMING", "FILE_DOWNLOAD"]))
        }
    }
}
