import AccountsKit
import DesignSystem
import Device
import Library
import OfflineStore
import ReadingProgress
import SourcesKit
import SwiftUI

/// The account sheet: "Who is reading?" at the top, then the three accounts with their state,
/// storage, appearance, language and About. Rarely needed, but when something is disrupted it
/// is where you see which server is struggling.
///
/// What a child profile does not see: import, "Sign out of all", the Wikipedia switch, and in
/// the sheets behind it sign-out and clearing storage.
///
/// The appearance (light/dark) is per device and therefore reads the standard UserDefaults
/// explicitly; everything else here is per profile via `defaultAppStorage`.
struct AccountsView: View {

    /// Where the sheet goes right after opening: `.statistics` from the deep link
    /// `akari://statistik` (reading-time widget); otherwise it stays on "Who is reading?".
    var start: AccountTarget?

    @Environment(AppCore.self) private var core
    @Environment(AccountRegistry.self) private var accounts
    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock
    @Environment(ReadingTimeLog.self) private var readingTime
    @Environment(ThemeChoice.self) private var themes
    @Environment(NotificationChoice.self) private var notifications
    @Environment(\.profile) private var profile
    @Environment(\.profileSettings) private var settings
    @Environment(\.dismiss) private var close
    @AppStorage(Appearance.storeKey, store: .standard) private var appearance = Appearance.system
        .rawValue
    @AppStorage(Summary.automaticKey) private var translateAutomatically = true
    @AppStorage(AuthorHeader.wikipediaKey) private var authorWikipedia = false
    @State private var language = ""
    @State private var scanner = false
    @State private var cache: Int64?
    @State private var path = NavigationPath()
    @State private var signOutAllQuestion = false
    @State private var filePicker = false
    @Environment(\.importFile) private var importFile
    @AppStorage(StartRow.lookupKey) private var bottom = StartRow.new.rawValue

    /// How many accounts are signed in; "Sign out of all" only shows when there is more than one.
    private var signedIn: [AccountSlot] { accounts.states.filter { $0.entry != nil }.map(\.slot) }
    private var server: [AccountRegistry.Status] {
        accounts.states.filter { !AccountSlot.multiple($0.provider) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ProfileRow()
                Section {
                    ForEach(server) { state in
                        NavigationLink(value: state.slot) {
                            AccountRow(
                                state: state, suggestion: accounts.suggested[state.provider],
                                failure: accounts.lastError[state.provider])
                        }
                    }
                    Button {
                        scanner = true
                    } label: {
                        Label(app: "setUp.code", systemImage: "qrcode.viewfinder")
                    }
                    // One action for all three: signing out each account separately is the
                    // same path three times over when switching devices.
                    if signedIn.count > 1, !profile.kind {
                        Button(role: .destructive) {
                            signOutAllQuestion = true
                        } label: {
                            Label(
                                app: "account.signOutAll", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } header: {
                    Text(app: "account.accounts")
                }

                // Any number of catalogs one below the other, each with its own row and
                // state; "Add catalog" opens an empty sheet.
                Section {
                    ForEach(accounts.catalogs) { state in
                        NavigationLink(value: state.slot) {
                            AccountRow(state: state)
                        }
                    }
                    NavigationLink(value: accounts.newSlot(.opds)) {
                        Label(app: "account.catalog.add", systemImage: "plus.circle")
                    }
                } header: {
                    HStack {
                        Text(app: "account.catalogs")
                        Spacer()
                        if accounts.catalogs.count > 1 {
                            Text(
                                verbatim: Phrase.from(
                                    "account.catalogs.connected",
                                    accounts.catalogs.filter { $0.phase == .signedIn }.count,
                                    accounts.catalogs.count))
                        }
                    }
                } footer: {
                    Text(app: "account.catalogs.text")
                }

                // One WebDAV folder per row: Nextcloud, ownCloud, any server with
                // PROPFIND. "Add folder" opens an empty sheet with the folder address.
                Section {
                    ForEach(accounts.folder) { state in
                        NavigationLink(value: state.slot) {
                            AccountRow(state: state)
                        }
                    }
                    NavigationLink(value: accounts.newSlot(.webdav)) {
                        Label(app: "account.folder.add", systemImage: "plus.circle")
                    }
                } header: {
                    HStack {
                        Text(app: "account.folderList")
                        Spacer()
                        if accounts.folder.count > 1 {
                            Text(
                                verbatim: Phrase.from(
                                    "account.catalogs.connected",
                                    accounts.folder.filter { $0.phase == .signedIn }.count,
                                    accounts.folder.count))
                        }
                    }
                } footer: {
                    Text(app: "account.folderList.text")
                }

                BulkSignIn()

                // The fourth source: files that arrived via AirDrop, Files or mail,
                // or are picked here with the file picker.
                Section {
                    LabeledContent {
                        let count = inventory.shelf.allTitles.filter {
                            $0.identifier.source.provider == Provider.device
                        }.count
                        Text(verbatim: Phrase.from("collection.counter", count))
                            .monospacedDigit()
                    } label: {
                        Text(app: "account.kind.geraet")
                    }
                    if !profile.kind {
                        Button {
                            filePicker = true
                        } label: {
                            Label(app: "device.doImport", systemImage: "square.and.arrow.down")
                        }
                    }
                } footer: {
                    Text(app: "device.hint")
                }
                .fileImporter(
                    isPresented: $filePicker, allowedContentTypes: FileType.all, allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result { importFile(urls) }
                }

                Section {
                    NavigationLink {
                        StorageView()
                    } label: {
                        LabeledContent {
                            Text(verbatim: Formats.bytes(stock.sum + (cache ?? 0)))
                                .monospacedDigit()
                        } label: {
                            Text(app: "storage.title")
                        }
                    }
                    NavigationLink(value: AccountTarget.statistics) {
                        LabeledContent {
                            Text(
                                verbatim: StatisticsView.time(
                                    ReadingStatistics(readingTime.sessions, period: .week).readingTime)
                            )
                            .monospacedDigit()
                        } label: {
                            Text(app: "statistics.title.sheet")
                        }
                    }
                } footer: {
                    Text(app: "storage.short")
                }

                // Report new podcast episodes; child profiles report nothing.
                if !profile.kind {
                    Section {
                        NavigationLink {
                            NotificationsView()
                        } label: {
                            LabeledContent {
                                Text(appKey: notifications.to ? "notifications.on" : "notifications.off")
                            } label: {
                                Text(app: "notifications.title")
                            }
                        }
                    }
                }

                Section {
                    Picker(selection: $appearance) {
                        ForEach(Appearance.allCases) { choice in
                            Text(appKey: choice.lookupKey).tag(choice.rawValue)
                        }
                    } label: {
                        Text(app: "appearance.titel")
                    }
                    ThemePicker(chosen: themes.chosen) { themes.set($0) }
                    // The app icon applies to the whole device; child profiles do not choose it.
                    #if os(iOS)
                        if !profile.kind { IconPicker() }
                    #endif
                    Picker(selection: $language) {
                        ForEach(LanguageChoice.offered, id: \.identifier) { choice in
                            // Each language names itself, hence `verbatim` rather than the catalog.
                            Text(verbatim: choice.name).tag(choice.identifier)
                        }
                    } label: {
                        Text(app: "language.title")
                    }
                    .onChange(of: language) { _, new in LanguageChoice.set(new, in: settings) }
                    Toggle(isOn: $translateAutomatically) {
                        Text(app: "text.automatic")
                    }
                    if !profile.kind {
                        Toggle(isOn: $authorWikipedia) {
                            Text(app: "author.switch")
                        }
                    }
                    Picker(selection: $bottom) {
                        ForEach(StartRow.allCases) { choice in
                            Text(appKey: choice.keyName).tag(choice.rawValue)
                        }
                    } label: {
                        Text(app: "start.bottom")
                    }
                } footer: {
                    if LanguageChoice.needsRestart(settings) {
                        Text(app: "language.restart")
                    } else if authorWikipedia {
                        Text(app: "author.switch.hint")
                    } else {
                        Text(app: "text.automatic.hint")
                    }
                }

                DiagnosticsSection()

                // Privacy and support open Safari; licenses live inside the app.
                Section {
                    LabeledContent {
                        Text(verbatim: Self.version)
                    } label: {
                        Text(app: "about.version")
                    }
                    Link(destination: AccountsView.privacy) {
                        Label(app: "about.privacy", systemImage: "hand.raised")
                    }
                    Link(destination: AccountsView.support) {
                        Label(app: "about.support", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label(app: "about.licenses", systemImage: "doc.text")
                    }
                    Text(app: "about.sources")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(app: "about.title")
                }
            }
            .paper()
            .navigationDestination(for: AccountSlot.self) { slot in
                SignInView(slot: slot)
            }
            .navigationDestination(for: AccountTarget.self) { target in
                switch target {
                case .statistics: StatisticsView()
                case .createProfile: CreateProfileView()
                case .manageProfile: ProfileManagement()
                case .editProfile(let profile): CreateProfileView(existing: profile)
                case .profileCloud(let profile): ProfileCloudView(profile: profile)
                case .addDevice(let profile): AddDeviceView(profile: profile)
                case .account(let slot): SignInView(slot: slot)
                }
            }
            .statisticsTargets()
            .targets()
            .onAppear {
                language = LanguageChoice.chosen(settings)
                guard path.isEmpty else { return }
                if let start {
                    path.append(start)
                    return
                }
                switch ProcessInfo.processInfo.environment["AKARI_PROBE"] {
                case "statistik": path.append(AccountTarget.statistics)
                case "statistik-titel":
                    path.append(AccountTarget.statistics)
                    path.append(StatisticsTarget.title(.week, nil))
                case "statistik-einzeln":
                    path.append(AccountTarget.statistics)
                    if let first = ReadingStatistics(readingTime.sessions, period: .total).titleValues.first {
                        path.append(StatisticsTarget.single(first.identifier))
                    }
                case "profilanlegen": path.append(AccountTarget.createProfile)
                case "wolke":
                    path.append(AccountTarget.manageProfile)
                    path.append(AccountTarget.editProfile(profile))
                    path.append(AccountTarget.profileCloud(profile))
                case "geraet-hinzufuegen":
                    path.append(AccountTarget.manageProfile)
                    path.append(AccountTarget.editProfile(profile))
                    path.append(AccountTarget.profileCloud(profile))
                    path.append(AccountTarget.addDevice(profile))
                default: break
                }
            }
            .navigationTitle(Text(app: "profile.title"))
            .toolbarTitleDisplayMode(.inline)
            // A sharing link from outside while the sheet is open: the question
            // "Adopt existing profile?" has to be presented here, not on the shell.
            .sharingQuestions(core.questions)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        close()
                    } label: {
                        Text(app: "action.done")
                    }
                }
            }
            .sheet(isPresented: $scanner, onDismiss: toSuggestion) {
                CodeScannerView()
            }
            .confirmationDialog(
                Text(app: "account.signOutAll.question"), isPresented: $signOutAllQuestion,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    Task {
                        for slot in signedIn { await accounts.signOut(slot) }
                    }
                } label: {
                    Text(app: "account.signOutAll")
                }
            } message: {
                Text(app: "account.signOut.text")
            }
            .task {
                // Walking the tree takes milliseconds for a few hundred files and
                // longer with a full cache, so it stays off the main thread.
                cache = await Task.detached(priority: .utility) { Cache.size() }
                    .value
            }
        }
    }

    /// After the code, go straight to the first sign-in sheet; otherwise the list looks
    /// unchanged and it seems like nothing happens.
    private func toSuggestion() {
        guard accounts.collectible.count < 2 else { return }
        if let first = accounts.states.first(where: {
            $0.account == nil && accounts.suggested[$0.provider] != nil
        }) {
            path.append(first.slot)
        } else if accounts.suggested[.opds] != nil {
            path.append(accounts.newSlot(.opds))
        } else if accounts.suggested[.webdav] != nil {
            path.append(accounts.newSlot(.webdav))
        }
    }

    /// "0.1.0 (1)", read from the bundle rather than hard-coded.
    static let privacy = URL(string: "https://github.com/ms-solutions-dev/akari#privacy")!
    static let support = URL(string: "https://github.com/ms-solutions-dev/akari/issues")!

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A row in the account sheet: kind, server and name, dot and state word.
struct AccountRow: View {

    let state: AccountRegistry.Status
    /// Address and name from the setup code while nobody is signed in yet.
    var suggestion: AccountRegistry.Suggestion? = nil
    /// Why the last sign-in failed, after a bulk sign-in.
    var failure: SignInError? = nil

    @Environment(\.dynamicTypeSize) private var fontSize

    var body: some View {
        // At accessibility sizes the state word sits below the name,
        // otherwise "Manga" becomes "Man...".
        HStack(alignment: large ? .top : .center, spacing: 12) {
            Circle()
                .fill(Self.color(state.phase))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let name = state.account?.displayName {
                    Text(verbatim: name)
                } else {
                    Text(appKey: "account.kind." + state.provider.rawValue)
                }
                if let account = state.account {
                    Text(verbatim: "\(account.server.host() ?? "") · \(account.username)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let suggestion {
                    Text(
                        verbatim: [suggestion.address.host() ?? "", suggestion.name].compactMap { $0 }.joined(
                            separator: " · ")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                if large { stateWord }
            }
            if !large {
                Spacer()
                stateWord
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The word on the right, or below: failure, suggestion, state.
    @ViewBuilder
    private var stateWord: some View {
        if state.account == nil, let failure {
            Text(appKey: failure.messageKey)
                .font(.footnote)
                .foregroundStyle(ColorTheme.failure.color)
                .multilineTextAlignment(large ? .leading : .trailing)
        } else if state.account == nil, suggestion != nil {
            Text(app: "account.status.suggested")
                .font(.footnote)
                .foregroundStyle(.tint)
                .multilineTextAlignment(large ? .leading : .trailing)
        } else {
            Text(appKey: state.phase.messageKey)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(large ? .leading : .trailing)
        }
    }

    private var large: Bool { fontSize.isAccessibilitySize }

    /// Green when it works; red when the user has to act; orange when the
    /// server is missing; gray when there is nothing or nothing is known yet.
    static func color(_ phase: AccountState) -> Color {
        signal(phase)?.color ?? .secondary
    }

    /// The level behind it: signal colors from the design system instead of `.red`/`.green`.
    static func signal(_ phase: AccountState) -> ColorTheme.Signal? {
        switch phase {
        case .signedIn: .ok
        case .expired, .disrupted, .certificate: .failure
        case .unreachable: .warning
        case .notConfigured, .unchecked: nil
        }
    }
}

/// The four color swatches: accent on paper, shared between light and dark, name below,
/// checkmark on the chosen one. A theme only changes accent and paper, which is what the swatch shows.
struct ThemePicker: View {

    let chosen: ColorTheme
    let choose: (ColorTheme) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app: "appearance.farbe")
            HStack(spacing: 12) {
                ForEach(ColorTheme.allCases) { theme in
                    Button {
                        Haptics.selection()
                        choose(theme)
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 0) {
                                ZStack {
                                    Color(hex: theme.paper.light)
                                    Circle().fill(Color(hex: theme.accent.light)).frame(width: 14, height: 14)
                                }
                                ZStack {
                                    Color(hex: theme.paper.dark)
                                    Circle().fill(Color(hex: theme.accent.dark)).frame(
                                        width: 14, height: 14)
                                }
                            }
                            .frame(width: 56, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        chosen == theme
                                            ? theme.accent.color : ColorTheme.muted.color.opacity(0.3),
                                        lineWidth: chosen == theme ? 2 : 1)
                            }
                            HStack(spacing: 3) {
                                Text(appKey: theme.lookupKey).font(.caption)
                                if chosen == theme {
                                    Image(systemName: "checkmark").font(.caption2.weight(.bold))
                                }
                            }
                            .foregroundStyle(chosen == theme ? theme.accent.color : ColorTheme.muted.color)
                        }
                        .frame(minWidth: TapTarget.atLeast, minHeight: TapTarget.atLeast)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen == theme ? [.isSelected] : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The sheets behind the account sheet that do not refer to a provider. `Identifiable`
/// so the shell can open the sheet with `sheet(item:)` and a target.
enum AccountTarget: Hashable, Identifiable {
    case statistics
    case createProfile
    case manageProfile
    case editProfile(Profile)
    /// A profile's "iCloud & Devices".
    case profileCloud(Profile)
    /// The "Add device" QR code.
    case addDevice(Profile)
    /// A single account's page, for the `konto-grimmory` probe.
    case account(AccountSlot)

    var id: AccountTarget { self }
}
