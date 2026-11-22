import AccountsKit
import AudioPlayer
import Bedrock
import CloudSync
import DesignSystem
import Device
import Library
import NetworkLocation
import OfflineStore
import PerformanceDiagnostics
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import SwiftUI
import WidgetBridge

/// The shell: three tabs, one account button. Everything else is sheets.
///
/// **Why three and not five:** favorites became "Saved" on the start page, the settings
/// became the account button at the top right; a tab used three times a year has no place
/// in the bar. Search carries the `.search` role: iOS 26 puts it as a magnifier at the right of
/// the bar, and the bar stays the same in every area.
///
/// The shell takes the `ProfileRegistry` and the ``ProfileContext`` of the active profile from the
/// ``AppCore`` (`AccountRegistry`, `LibraryService`, reading time, theme) and passes everything down
/// as environment; on first launch without an account it lays the welcome flow over it, and
/// a setup link (`akari://einrichten?...`) arrives here through `onOpenURL`.
/// On opening, the library is filled from the store first, then the sources are queried;
/// if an account changes, once more.
///
/// **A profile switch swaps the context completely** and resets the tabs with
/// `.id(profile)`: every view below starts with the new registry and
/// library instead of carrying old state along. Offline store, network watch, player and the
/// device source stay (shared); the running player stops. The old profile's queue
/// stays on disk and is handed back at the next switch. On launch the last profile
/// opens silently.
///
/// **Profiles, context, player, offline store and read call belong to the
/// ``AppCore``,** which `AkariApp.init` creates before any view exists: the widget's play button
/// runs in the app's process even without a scene, and then the player
/// must already be there. The shell holds the core and reads everything from there; if the app starts
/// with a running player, it shows the mini player without reloading anything.
///
/// On iPad the bar turns into a sidebar (`sidebarAdaptable`).
/// The genres appear in it as sections **per kind** below the three tabs:
/// one sidebar, two levels (the system sidebar and the library's genre split view
/// used to stand side by side, HIG "Avoid nesting sidebars"). Per kind rather than "genres of the chosen kind",
/// because per the HIG a sidebar is persistent: its rows must not depend on which
/// segment is currently chosen in the content, which is how Books ("Library", "Collections") and
/// Podcasts ("Stations", "Channels") group too. The sections appear only in the sidebar
/// (`sidebarOnly`): in the portrait pill the bar stays as it was; there the library's genre
/// row is the way. On iPhone the sections do not exist at all; `sidebarOnly`
/// does not apply there, and the genres used to show as tabs "Adventure, Shonen, More" in the
/// bar, so they hang on the wide size class.
///
/// The mini player sits as `tabViewBottomAccessory` above the bar and is not a tab.
///
/// **Widget and handoff:** the shell observes the active profile's continue-reading row
/// and has the ``SnapshotWriter`` write it into the app group,
/// after every state change, after refreshing, on profile switch. A tap on the widget
/// and a handoff from the other device arrive as the same deep link `akari://lesen/...`;
/// if the active profile does not know the title, the shell says so
/// (`deeplink.unbekannt`) instead of silently doing nothing. If the link arrives before the
/// library is loaded from the store (cold start from the widget), it waits until then.
///
/// **Continue listening and reading statistics:** the ``WidgetWatcher`` in the shell's background
/// observes player, shelf and reading-time log and has the two writers
/// store the snapshots. The listening widget's play/pause button does not go through the
/// shell but through the ``AppCore`` (``AppCore/switchContinueListening(identifier:link:)``).
/// `akari://statistik` opens the account sheet directly on the reading statistics.
public struct ShellView: View {

    /// The chosen area, as state so that a probe or a deep link can set it
    /// and search opens programmatically.
    @State private var area: Area =
        Area(rawValue: ProcessInfo.processInfo.environment["AKARI_BEREICH"] ?? "") ?? .start
    /// The app's core: profiles, context, player, offline store, read call, device source.
    @State private var core: AppCore
    private var profiles: ProfileRegistry { core.profiles }
    private var context: ProfileContext { core.context }
    private var accounts: AccountRegistry { context.accounts }
    private var inventory: LibraryService { context.inventory }
    private var themes: ThemeChoice { context.themes }
    private var readingTime: ReadingTimeLog { context.readingTime }
    private var reader: ReadCall { core.reader }
    private var stock: StockService { core.stock }
    private var metering: NetworkMeter { core.metering }
    private var player: Player { core.player }
    /// The fourth source: files on the device, always there, without an account.
    private var device: DeviceSource { core.device }
    private var listenSnapshot: ContinueListeningWriter { core.listenSnapshot }
    @State private var notices = Notices()
    @State private var collectionQuestion = CollectionQuestion()
    @State private var network = NetworkWatch()
    @State private var welcome = false
    /// What is currently arriving; the shell shows the notice.
    @State private var imported: ImportNotice?
    @State private var snapshot = SnapshotWriter()
    @State private var statisticsSnapshot = ReadingStatisticsWriter()
    /// The account sheet, opened by the deep link, with the target it continues to.
    @State private var accountCall: AccountTarget?
    /// A deep link that arrived before the library; tried once more after the store is read.
    @State private var openLink: Deeplink?
    /// A link to a title this profile does not know; the shell says so.
    @State private var linkUnknown = false
    @AppStorage(Appearance.storeKey) private var appearance = Appearance.system.rawValue
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Stable calls for the environment; see ``ShellCaller``.
    @State private var caller = ShellCaller()
    @Environment(\.horizontalSizeClass) private var width

    /// How old the state may be before returning to the app queries again:
    /// a book just added in Grimmory should be there when picking up the phone
    /// again; querying the servers every two minutes would waste the tunnel.
    static let freshFor: TimeInterval = 10 * 60

    /// The shell above the app's core: in operation ``AppCore/standard()``, with
    /// `-attrappen` ``AppCore/mocks()``; both are created by `AkariApp.init`.
    public init(core: AppCore) {
        _core = State(initialValue: core)
        Typography.shapeNavigationBar()
    }

    /// For tests: registry and context builder without keychain.
    /// - Parameter profiles: The profile registry with mocks.
    /// - Parameter context: Builds a profile's context; is called once more
    ///   on switching.
    /// - Parameter preview: Without welcome flow and without server check.
    init(
        profiles: ProfileRegistry,
        context: @escaping (Profile, ProfileStore, DeviceSource) -> ProfileContext,
        device: DeviceSource, preview: Bool = false
    ) {
        self.init(core: AppCore(profiles: profiles, context: context, device: device, preview: preview))
    }

    private var preview: Bool { core.preview }
    private var disruption: (probe: DisruptionProbe, sources: [MockSource], transport: MockTransport)? {
        core.disruption
    }

    /// What the tabs and the start run hang on: number, name and cloud switch of the
    /// profile. A renamed profile gets a new context (the zone gets the
    /// name), as does one with a flipped sync switch, and both reload like a
    /// switched one.
    private var contextKey: String {
        "\(context.profile.id)/\(context.profile.name)/\(context.profile.cloudSync)"
    }

    /// What the widget should show: the first four of the continue-reading row and the
    /// profile name; when the value changes, it is written.
    private func widgetJob(_ shelf: Shelf) -> SnapshotWriter.Job {
        SnapshotWriter.Job(
            readings: Array(shelf.continueReading.prefix(ContinueReadingSnapshot.cap)),
            profile: context.profile.name, multipleProfiles: profiles.all.count > 1)
    }

    /// The three tabs and the genre sections, separated from the rest, otherwise the
    /// compiler gives up on the long modifier chain ("unable to type-check in
    /// reasonable time"). If a chosen genre is missing after refreshing or the
    /// width becomes narrow (Split View, Slide Over), the tab would be empty; then it goes
    /// back to the library.
    private var tabs: some View {
        TabView(selection: $area) {
            Tab(value: Area.start) {
                StartView(area: $area)
            } label: {
                Label(app: "tab.start", systemImage: "house")
            }
            Tab(value: Area.library) {
                LibraryView()
            } label: {
                Label(app: "tab.library", systemImage: "books.vertical")
            }
            Tab(value: Area.search, role: .search) {
                SearchView()
            } label: {
                Label(app: "tab.search", systemImage: "magnifyingglass")
            }
            ForEach(width == .regular ? genreSections : [], id: \.kind) { part in
                TabSection {
                    ForEach(part.genres) { genre in
                        Tab(value: Area.genre(part.kind, genre.lookupKey)) {
                            LibraryView(genre: (part.kind, genre.lookupKey))
                        } label: {
                            Label {
                                GenreRow.name(genre)
                            } icon: {
                                Image(systemName: "tag")
                            }
                        }
                    }
                } header: {
                    part.title
                }
                .tabPlacement(.sidebarOnly)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // Widget and genre check listen to the shelf in a small view of their own: if they read
        // it here, the whole shell with its tabs would recompute on every reading state (every 2 s
        // while reading). Genres only change on refresh, so the fetch
        // states are observed, not the genres themselves.
        .background {
            ShelfWatchers(
                inventory: inventory, job: widgetJob,
                schedule: { snapshot.schedule($0, sources: sourceAccess) },
                fetched: checkGenre)
        }
        // Bundling or splitting series changes the entries, and with them their genres.
        .onChange(of: inventory.bookSeriesList) { checkGenre() }
        .onChange(of: width) { checkGenre() }
    }

    private func checkGenre() {
        guard case .genre(let kind, let lookupKey) = area else { return }
        let present =
            width == .regular
            && ShellView.sidebar(inventory.genres(kind)).contains { $0.lookupKey == lookupKey }
        if !present { area = .library }
    }

    /// The sidebar's genre sections: per kind with at least two genres
    /// one, titled like the segment; with only one kind simply "Genres", because
    /// "Manga" above the only genres distinguishes nothing.
    private var genreSections: [(kind: Kind, genres: [Shelf.Genre], title: Text)] {
        let kinds = inventory.shelf.kinds
        return kinds.compactMap { kind in
            let genres = ShellView.sidebar(inventory.genres(kind))
            guard genres.count >= 2 else { return nil }
            let title = kinds.count > 1 ? Text(appKey: kind.segmentKey) : Text(app: "library.genres")
            return (kind, genres, title)
        }
    }

    /// At most the eight largest genres in the sidebar, without "no genre"
    /// (over twenty raw entries otherwise). All genres remain
    /// in the library's genre row.
    static func sidebar(_ genres: [Shelf.Genre]) -> [Shelf.Genre] {
        Array(genres.filter { $0.lookupKey != .without }.prefix(8))
    }

    /// What opens as a full-screen sheet: comic and book; audiobooks do not, see ``listenTitle``.
    private var readingTitle: Binding<Title?> {
        Binding(
            get: { reader.title.flatMap { $0.kind.isAudible ? nil : $0 } },
            set: { reader.title = $0 })
    }

    /// The audiobook whose player lies as a layer above the app.
    private var listenTitle: Title? {
        reader.title.flatMap { $0.kind.isAudible ? $0 : nil }
    }

    /// Where the user is, for performance diagnostics: the reader if one is open.
    private var diagnosticsLocation: String {
        if let title = reader.title {
            let readerKind =
                title.kind.isAudible ? "Audiobook" : (title.kind == .book ? "Book reader" : "Comic reader")
            return "\(readerKind) · \(title.name)"
        }
        switch area {
        case .start: return "Start"
        case .library: return "Library"
        case .search: return "Search"
        case .genre(let kind, _): return "Genre · \(kind.rawValue)"
        }
    }

    public var body: some View {
        let _ = Performance.build("Shell")
        tabs
            // A profile switch resets the tabs; registry, library and
            // everything below belong to the new profile, not the old one.
            .id(contextKey)
            // The mini player sits above the bar as soon as an audiobook is in the player
            // (Books pattern); a tap opens the sheet again.
            .miniPlayer(player) {
                if let title = reader.ongoing { reader.open(title) }
            } close: {
                player.close()
                reader.ongoing = nil
            }
            // Before the environment values, not after: the alert reads library and notices
            // from the environment; outside it the app crashes on the first frame.
            .collectionQuestion(collectionQuestion)
            // "Adopt existing profile?" when accepting a sharing; here for the link from
            // outside; the camera sheet carries the dialog itself.
            .sharingQuestions(core.questions)
            // For the same reason the share sheet hangs here and not behind the chain:
            // it once lacked the library service, later the network watch;
            // environment values added one by one go stale with every new dependency.
            .sheet(item: Bindable(reader).titleToShare) { title in ShareSheet(title: title) }
            // The account sheet from the deep link `akari://statistik`; here for the same
            // reason: it reads registry, library and reading time from the environment.
            .sheet(item: $accountCall) { target in AccountsView(start: target) }
            .background {
                WidgetWatcher(
                    player: player, inventory: inventory, reader: reader, readingTime: readingTime,
                    profile: context.profile.name,
                    multipleProfiles: profiles.all.count > 1, listenWriter: listenSnapshot,
                    statisticsWriter: statisticsSnapshot, sources: sourceAccess)
            }
            .environment(core)
            .environment(profiles)
            .environment(\.profile, context.profile)
            .environment(\.profileSettings, context.settings)
            .defaultAppStorage(context.settings)
            .environment(accounts)
            .environment(inventory)
            .environment(\.device, device)
            .environment(themes)
            .environment(reader)
            .environment(notices)
            .environment(collectionQuestion)
            .environment(stock)
            .environment(network)
            .environment(metering)
            .environment(player)
            .environment(readingTime)
            .environment(context.notifications)
            .environment(\.imageTransport, imageTransport)
            .theme(themes.chosen)
            .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
            // With the profile number as id: runs at launch and again after every switch,
            // for the new context. Preview skips only the network watch and
            // the welcome flow: store first, then check accounts and query sources
            // is the same path; the disruption probe tests exactly it.
            .task(id: contextKey) {
                inventory.keep = stock.completed
                inventory.stockTitle = stock.snapshots
                // `AKARI_LINK=akari://statistik`: a deep link at launch, as if
                // it came from the widget; `simctl openurl` asks "Open in Akari?"
                // since iOS 26, and nobody presses the button in a test run.
                if let probe = ProcessInfo.processInfo.environment["AKARI_LINK"],
                    let url = URL(string: probe)
                {
                    open(url)
                }
                if !preview {
                    network.launch()
                    // A child profile sets nothing up, so no welcome flow.
                    if !accounts.configured && !profiles.active.kind { welcome = true }
                }
                #if DEBUG
                    // The welcome flow for the screenshot: the mocks are
                    // set up, so it would otherwise never appear. Debug build only;
                    // the App Store build has no such thing.
                    if preview, ProcessInfo.processInfo.environment["AKARI_PROBE"] == "willkommen" {
                        welcome = true
                    }
                    // Grimmory's account page (catalog, libraries) for the screenshot.
                    if ProcessInfo.processInfo.environment["AKARI_PROBE"] == "konto-grimmory",
                        let slot = accounts.states.first(where: { $0.provider == .grimmory })?.slot
                    {
                        accountCall = .account(slot)
                    }
                #endif
                // Empty if nobody has read the store yet; the audiobook starter may already have read it
                // when the widget button started the app in the background.
                caller.importTarget = importJob
                caller.welcomeTarget = { welcome = true }
                if !inventory.storeRead { await inventory.fromStore() }
                tryOpenLink()
                // Bring cover folder and cache under their caps, once per launch,
                // in the background. Do not wait: the start page fetches its covers right now.
                let limit = Cache.limit()
                Task { await ImageLoader.shared.cleanUpOnce(until: Int(Cache.coverFraction(limit))) }
                Task.detached(priority: .utility) { Cache.cleanUp(until: limit) }
                async let check: Void = accounts.verify()
                await inventory.refresh()
                // Backfill data packages for kept items from before, now that the catalogs are loaded.
                stock.supplement(
                    title: { inventory.title($0) }, source: { inventory.source($0) },
                    transport: { imageTransport($0) })
                tryOpenLink(lastAttempt: true)
                await check
                resumeDownloads()
                if let disruption {
                    await disruption.probe.play(
                        DisruptionProbe.Stage(
                            sources: disruption.sources, transport: disruption.transport, network: network,
                            inventory: inventory,
                            reader: reader, stock: stock, player: player, metering: metering,
                            imageTransport: imageTransport))
                }
            }
            // A changed certificate on a running account: the question with both fingerprints,
            // not a silent "unreachable". Trusting rechecks the
            // computer's accounts and queries the sources once more.
            .sheet(item: Binding(get: { accounts.certificateQuestion }, set: { _ in })) { question in
                CertificateQuestionView(question: question) { trusted in
                    if trusted {
                        try? accounts.trust(question)
                        Task {
                            for slot in accounts.slots(for: question.host) { await accounts.verify(slot) }
                            await inventory.refresh()
                        }
                    } else {
                        accounts.decline(question)
                    }
                }
                .theme(themes.chosen)
            }
            // A link from a probe with mocks only exists after the core is built,
            // hence observed rather than read once.
            .onChange(of: core.sampleLink, initial: true) { _, url in
                guard let url else { return }
                core.sampleLink = nil
                open(url)
            }
            .onChange(of: accounts.states.map(\.entry)) {
                Task { await inventory.refresh() }
            }
            // A different profile (or a renamed one, or one with a flipped
            // cloud switch): player off, context new, the profile's language to the system.
            .onChange(of: profiles.active) { _, new in
                guard
                    new.id != context.profile.id || new.name != context.profile.name
                        || new.cloudSync != context.profile.cloudSync
                else { return }
                core.switchTo(to: new)
                if !preview { LanguageChoice.adopt(from: context.settings) }
            }
            // What is finished on the device is known to the shelf: the "Keep" filter.
            .onChange(of: stock.completed) { _, new in inventory.keep = new }
            // Kept items also appear on the shelf without a catalog, from their data package.
            .onChange(of: stock.snapshots) { _, new in inventory.stockTitle = new }
            // Network back: what was read offline now goes to the server,
            // and an interrupted download continues.
            .onChange(of: network.route.usable) { _, usable in
                guard usable else { return }
                Task {
                    await inventory.supply()
                    resumeDownloads()
                }
            }
            // Different path, different line: what the Wi-Fi carried says nothing about the tunnel.
            .onChange(of: network.state) { metering.forget() }
            // Back in the app: query again if the state is older than ten minutes.
            // Until then this only happened on opening and on pulling down.
            .onChange(of: scene) { _, new in
                // Into the background: the widget snapshots go out immediately.
                if new == .background {
                    Task { await inventory.secureStore() }
                    Task { await snapshot.immediately() }
                    Task { await listenSnapshot.immediately() }
                    statisticsSnapshot.immediately()
                }
                // Back in the foreground: reconcile the zone; a silent push does
                // not always arrive (throttled in the core).
                if new == .active {
                    core.sameCloudSince()
                    core.checkEpisodesOccasionally()
                }
                guard new == .active, !preview, accounts.configured else { return }
                let stale =
                    inventory.renewed.map { Date().timeIntervalSince($0) > ShellView.freshFor } ?? true
                Task {
                    if stale { await inventory.refresh() } else { await inventory.supply() }
                }
            }
            // Light and tilt rest while a full-screen sheet lies above or the app
            // is not in front; nobody sees the covers below.
            .environment(\.lightHeld, reader.title != nil || scene != .active)
            .onChange(of: diagnosticsLocation, initial: true) { _, place in Performance.place(place) }
            // While a full-screen reader is open, reading states do not enter the observed shelf
            // (``LibraryService/holdsBack``); otherwise the start page behind it would rebuild every two
            // seconds. Not audiobooks: their player lies above the app, which stays
            // in use.
            .onChange(of: reader.title.map { !$0.kind.isAudible } ?? false, initial: true) { _, fullscreen in
                inventory.holdsBack = fullscreen
            }
            // The comic reader opens manga full-screen, the plugged-in book reader opens books;
            // audiobooks show the notice sheet until the player is there.
            // Audiobooks come not as a sheet but as a layer above (see ``listenTitle``).
            .fullSheet(item: readingTitle) { title in
                Group {
                    switch title.kind {
                    case .manga:
                        ComicReaderSheet(title: title)
                            .theme(themes.chosen)
                            .modifier(
                                CloseGesture(closed: {
                                    var silent = Transaction()
                                    silent.disablesAnimations = true
                                    withTransaction(silent) { reader.title = nil }
                                })
                            )
                            .presentationBackground(.clear)
                    case .book:
                        // The book reader closes like the player: it follows the finger, the app
                        // is visible beneath, and it slides out with momentum; afterwards
                        // the full-screen sheet closes without a motion of its own (device test: "hangs").
                        // `theme` before the drag, otherwise its paper would stay in place.
                        BookReaderSheet(title: title)
                            .theme(themes.chosen)
                            .modifier(
                                CloseGesture(closed: {
                                    var silent = Transaction()
                                    silent.disablesAnimations = true
                                    withTransaction(silent) { reader.title = nil }
                                })
                            )
                            .presentationBackground(.clear)
                    case .audiobook, .podcast: AudioPlayerSheet(title: title).theme(themes.chosen)
                    }
                }
                .environment(player)
                .environment(inventory)
                .environment(\.device, device)
                .environment(stock)
                .environment(network)
                .environment(reader)
                .environment(notices)
                .environment(readingTime)
                .environment(\.imageTransport, imageTransport)
                // The sheet itself is visible: its light (loading view, player) breathes.
                // The theme sits inside each reader; outside it would paint its paper behind the drag.
                .environment(\.lightHeld, scene != .active)
            }
            // The player as a layer above everything, as in Apple Music: on dragging down it follows
            // the finger completely, the app is visible beneath, and it slides out with the finger's
            // momentum (as a full-screen sheet the drag "hung").
            .overlay {
                ZStack {
                    if let title = listenTitle {
                        AudioPlayerSheet(title: title)
                            // Before the drag: `theme` paints its paper; outside, it stayed
                            // in place while dragging and covered the app below.
                            .theme(themes.chosen)
                            .modifier(
                                CloseGesture(closed: {
                                    var silent = Transaction()
                                    silent.disablesAnimations = true
                                    withTransaction(silent) { reader.title = nil }
                                })
                            )
                            .environment(\.closePlayer) {
                                withAnimation(Motion.sheet(reduceMotion)) { reader.title = nil }
                            }
                            .environment(player)
                            .environment(inventory)
                            .environment(\.device, device)
                            .environment(stock)
                            .environment(network)
                            .environment(reader)
                            .environment(notices)
                            .environment(readingTime)
                            .environment(\.imageTransport, imageTransport)
                            .environment(\.lightHeld, scene != .active)
                            // Like a sheet for VoiceOver: a closed-off area, the app
                            // hidden beneath, the Z gesture closes.
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityAction(.escape) {
                                withAnimation(Motion.sheet(reduceMotion)) { reader.title = nil }
                            }
                            .transition(.move(edge: .bottom))
                    }
                }
                .animation(Motion.sheet(reduceMotion), value: listenTitle?.identifier)
            }
            .noticeMessage(notices)
            .linkHandling(open: open, handoff: episode, unknown: $linkUnknown)
            .environment(\.importFile, caller.importFile)
            // "Connect server" from the empty library.
            .environment(\.openWelcome, caller.welcome)
            .alert(item: $imported, content: ShellView.message)
            // The cover is an outer modifier: what the chain above puts into the environment
            // does not arrive here; the core must come along, otherwise the camera sheet
            // of the welcome flow crashes on first access.
            .fullSheet(isPresented: $welcome) {
                WelcomeView()
                    .environment(core)
                    .environment(accounts)
                    // The account page shows the catalog and rebuilds it after the library choice.
                    .environment(inventory)
                    .environment(profiles)
                    // First launch offers "Open own EPUB" and the sample shelf;
                    // that too would not otherwise get past the cover.
                    .environment(\.importFile, caller.importFile)
                    .theme(themes.chosen)
            }
    }

    /// A handoff from the other device; the same path as a deep link.
    private func episode(_ activity: NSUserActivity) {
        ReadingHandoff.link(from: activity).map { episode($0) }
    }

    private func open(_ url: URL) {
        if url.isFileURL {
            Task { await importFile([url]) }
        } else if let code = SetupCode(url) {
            // "Add device": accept the sharing, create the profile or adopt one with the
            // same name, switch to it; then the welcome flow for the
            // passwords. `nil` means the reader cancelled.
            if code.sharing != nil {
                Task {
                    do throws(CloudError) {
                        if try await core.acceptSharing(code) != nil { welcome = true }
                    } catch {
                        imported = ImportNotice(
                            lookupKey: "cloud.acceptance.error", text: CloudRow.reason(error))
                    }
                }
                return
            }
            accounts.adopt(code)
            if let person = code.person {
                profiles.rename(to: person, ifUntouched: !accounts.configured)
            }
            welcome = true
        } else if let link = Deeplink(url) {
            episode(link)
        }
    }

    private var importJob: @MainActor ([URL]) -> Void {
        { urls in Task { await importFile(urls) } }
    }

    private static func message(_ message: ImportNotice) -> Alert {
        Alert(title: Text(appKey: message.lookupKey), message: message.text.map { Text(verbatim: $0) })
    }

    /// The transport for covers, pages and files: the core's measured one.
    private var imageTransport: @Sendable (Provider) -> any Transport { core.imageTransport }

    /// What was left over while fetching (app quit, network gone) continues as soon as a
    /// usable network is there and the library knows the title, via `Range` from the
    /// last position. Only at home: on the road the offline store waits as always.
    private func resumeDownloads() {
        guard network.route.largeAmountsAcceptable else { return }
        for identifier in stock.interrupted {
            // The data package first: a title the catalog currently does not deliver still resumes.
            guard let title = stock.entry(identifier)?.title ?? inventory.title(identifier),
                let source = inventory.source(identifier.source)
            else {
                continue
            }
            Diagnostics.step("Offline store: resuming \(title.name)", since: nil, area: "Stock")
            stock.requestKeep(title, source: source, transport: imageTransport(identifier.source.provider))
        }
    }

    /// Take in files, from "Open in Akari" (AirDrop, Files, mail;
    /// the file then lies in the inbox and is deleted afterwards) or from the
    /// file picker (with security-scoped access). Afterwards the title is on the shelf and
    /// the shell says what arrived.
    private func importFile(_ urls: [URL]) async {
        var names: [String] = []
        var failure: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let identifier = try device.importFile(url)
                names.append((try? await device.title(identifier).name) ?? url.lastPathComponent)
            } catch {
                Diagnostics.network.error(
                    "Import failed: \(String(describing: error), privacy: .public)")
                failure.append(url.lastPathComponent)
            }
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
        await inventory.refresh(only: device.identifier)
        if !names.isEmpty { Haptics.success() }
        imported = ImportNotice(
            lookupKey: failure.isEmpty ? "device.imported" : "device.import.error",
            text: (names + failure.map { "✗ " + $0 }).joined(separator: "\n"))
    }

    /// A deep link: title and series take the "To series" path (Start takes
    /// the target onto its stack), reading opens the reader if the library knows the
    /// title. If it does not know it because it is not yet loaded from the store
    /// (cold start from the widget or by handoff), the link waits; if it still does not know it
    /// after refreshing, the title belongs to an account this
    /// profile does not have, and the shell says so.
    private func episode(_ link: Deeplink, lastAttempt: Bool = false) {
        let stillLoading = inventory.shelf.empty && inventory.renewed == nil && !lastAttempt
        switch link {
        case .title(let identifier): reader.jump(to: .title(identifier))
        case .series(let identifier): reader.jump(to: .series(identifier))
        case .read(let identifier):
            if let title = inventory.title(identifier) {
                reader.open(title)
            } else if stillLoading {
                openLink = link
            } else {
                linkUnknown = true
            }
        case .continueReading:
            if let first = inventory.shelf.continueReading.first {
                reader.open(first.title)
            } else if stillLoading {
                openLink = link
            }
        case .statistics:
            reader.title = nil
            accountCall = .statistics
        }
    }

    /// The link that arrived before the library: once more after the store and after
    /// refreshing; after refreshing it is the last attempt.
    private func tryOpenLink(lastAttempt: Bool = false) {
        guard let link = openLink else { return }
        openLink = nil
        episode(link, lastAttempt: lastAttempt)
    }

    /// Headers and transport per source, for the widgets' covers.
    private var sourceAccess: SnapshotWriter.SourceAccess { core.sourceAccess }
}

/// The bar's areas: the three tabs and, on iPad in the sidebar, a
/// genre of a kind. A value so that a deep link or a probe can name a tab:
/// `AKARI_BEREICH=bibliothek`, for a genre `genre:buch:Thriller` (`genre:manga:-` for "No genre").
public enum Area: Hashable, Sendable {
    case start, library, search
    case genre(Kind, Shelf.Genre.EntryKey)

    public init?(rawValue: String) {
        switch rawValue {
        case "start": self = .start
        case "bibliothek": self = .library
        case "suche": self = .search
        default:
            let share = rawValue.split(separator: ":", maxSplits: 2).map(String.init)
            guard share.count == 3, share[0] == "genre", let kind = Kind(rawValue: share[1]) else {
                return nil
            }
            // Raw ("thriller") as stored ("Thriller"): the same name as on the shelf.
            self = .genre(kind, share[2] == "-" ? .without : .name(GenreNames.normal(share[2])))
        }
    }

    public var rawValue: String {
        switch self {
        case .start: "start"
        case .library: "bibliothek"
        case .search: "suche"
        case .genre(let kind, .without): "genre:\(kind.rawValue):-"
        case .genre(let kind, .name(let name)): "genre:\(kind.rawValue):\(name)"
        }
    }
}

extension View {

    /// What comes in from outside: links (`onOpenURL`), handoff activities and the
    /// notice when a link points to a title this profile does not know,
    /// bundled so that the shell's chain does not get longer (the compiler gives
    /// up on it otherwise).
    fileprivate func linkHandling(
        open: @escaping (URL) -> Void, handoff: @escaping (NSUserActivity) -> Void,
        unknown: Binding<Bool>
    ) -> some View {
        onOpenURL(perform: open)
            .onContinueUserActivity(ReadingHandoff.kind, perform: handoff)
            .alert(Text(app: "deeplink.unknown.title"), isPresented: unknown) {
                Button {
                    unknown.wrappedValue = false
                } label: {
                    Text(app: "action.ok")
                }
            } message: {
                Text(app: "deeplink.unknown.text")
            }
    }

    /// The mini player as tab accessory, on iOS only; on the Mac (swift test)
    /// the accessory does not exist, and the player stays in the sheet.
    @ViewBuilder
    fileprivate func miniPlayer(
        _ player: Player, open: @escaping () -> Void, close: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
            // `isEnabled`, not `if` in the content: empty content still draws the
            // glass surface above the bar. That only exists from
            // 26.1; before that the empty content remains, a bar when nothing plays.
            if #available(iOS 26.1, *) {
                tabViewBottomAccessory(isEnabled: player.audiobook != nil) {
                    MiniPlayerView(
                        player: player, running: player.running, open: open, close: close)
                }
            } else {
                tabViewBottomAccessory {
                    if player.audiobook != nil {
                        MiniPlayerView(
                            player: player, running: player.running, open: open, close: close)
                    }
                }
            }
        #else
            self
        #endif
    }

    /// A sheet above everything: full-screen on the phone, on the Mac (where there is
    /// no such thing and `swift test` runs) an ordinary sheet.
    fileprivate func fullSheet<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
            return fullScreenCover(isPresented: isPresented, content: content)
        #else
            return sheet(isPresented: isPresented, content: content)
        #endif
    }

    fileprivate func fullSheet<Value: Identifiable, Content: View>(
        item: Binding<Value?>, @ViewBuilder content: @escaping (Value) -> Content
    ) -> some View {
        #if os(iOS)
            return fullScreenCover(item: item, content: content)
        #else
            return sheet(item: item, content: content)
        #endif
    }
}

struct ImportNotice: Identifiable {
    let lookupKey: String
    let text: String?
    var id: String { lookupKey + (text ?? "") }
}

/// The import as environment value; the account sheet calls it with the picker's files.
struct ImportKey: EnvironmentKey {
    static let defaultValue: @MainActor ([URL]) -> Void = { _ in }
}

extension EnvironmentValues {
    var importFile: @MainActor ([URL]) -> Void {
        get { self[ImportKey.self] }
        set { self[ImportKey.self] = newValue }
    }
}

/// The "On this device" source as environment value; not `@Observable`, it is a
/// folder; whoever changes it refreshes the library.
struct DeviceKey: EnvironmentKey {
    static let defaultValue: DeviceSource? = nil
}

extension EnvironmentValues {
    var device: DeviceSource? {
        get { self[DeviceKey.self] }
        set { self[DeviceKey.self] = newValue }
    }
}

/// Calls the shell puts into the environment, created once so that they stay equal for SwiftUI.
/// A closure that is new on every pass counted as a changed environment value, and every
/// view that reads it (Start, the empty shelf, the accounts) recomputed on every
/// re-evaluation of the shell. The shell sets the target at launch.
@MainActor
final class ShellCaller {
    var importTarget: (@MainActor ([URL]) -> Void)?
    var welcomeTarget: (@MainActor () -> Void)?

    lazy var importFile: @MainActor ([URL]) -> Void = { [weak self] urls in self?.importTarget?(urls) }
    lazy var welcome: @MainActor () -> Void = { [weak self] in self?.welcomeTarget?() }
}

/// Listens to the shelf so the shell does not have to: the widget gets what the start page
/// shows, and after a fetch it checks whether the chosen genre is still there.
private struct ShelfWatchers: View {
    let inventory: LibraryService
    let job: (Shelf) -> SnapshotWriter.Job
    let schedule: (SnapshotWriter.Job) -> Void
    let fetched: () -> Void

    var body: some View {
        Color.clear
            .onChange(of: job(inventory.shelf), initial: true) { _, new in schedule(new) }
            .onChange(of: inventory.shelf.extracts.map(\.state)) { fetched() }
            .accessibilityHidden(true)
    }
}
