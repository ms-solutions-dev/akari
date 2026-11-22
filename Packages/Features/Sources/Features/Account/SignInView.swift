import AccountsKit
import Bedrock
import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The sign-in sheet for an account; once signed in, its profile card.
///
/// **One button, four answers:** wrong address, wrong password, unknown certificate,
/// disrupted server. Each case gives its own message. The certificate arrives as a sheet
/// with the fingerprint; after trusting it, sign-in runs again by itself. The password stays
/// in the field until sign-in is through and is then cleared; only the key or token is stored.
struct SignInView: View {

    let slot: AccountSlot
    private var provider: Provider { slot.provider }

    init(slot: AccountSlot) {
        self.slot = slot
    }

    /// The single slot of a server.
    init(provider: Provider) {
        self.slot = .server(provider)
    }

    @Environment(AccountRegistry.self) private var accounts
    @Environment(LibraryService.self) private var inventory
    @State private var reconciling = false
    @State private var newQuestion = false
    @State private var builds = false
    /// The server's libraries if there is more than one; otherwise empty and the section is
    /// omitted.
    @State private var libraries: [SubLibrary] = []
    @State private var choiceChanged = false
    /// After sign-in: the question of which libraries should go into the app.
    @State private var choiceAfterSignIn: ChoiceQuestion?

    struct ChoiceQuestion: Identifiable {
        let identifier: SourceID
        let libraries: [SubLibrary]
        let title: Int
        var id: SourceID { identifier }
    }
    @Environment(\.profile) private var profile
    @Environment(\.dismiss) private var back
    @State private var address = ""
    /// OPDS catalog only: which server it is, since the catalog path depends on it.
    @State private var template = OpdsTemplate.other
    @State private var name = ""
    @State private var password = ""
    @State private var running = false
    @State private var failure: SignInError?
    @State private var certificate: CertificateQuestion.Unresolved?
    @State private var retry = false
    @State private var signOutQuestion = false
    /// When the last check happened. Without it the button visibly did nothing when the
    /// server answered "signed in" within 100 ms.
    @State private var checked: Date?

    /// A new OPDS slot has no row yet, so the state is empty.
    private var state: AccountRegistry.Status { accounts.state(slot) ?? AccountRegistry.Status(slot: slot) }

    var body: some View {
        Form {
            if let entry = state.entry {
                profileCard(entry)
                if state.phase == .expired {
                    formView
                }
            } else {
                formView
            }
        }
        .paper()
        .navigationTitle(
            state.account?.displayName.map { Text(verbatim: $0) }
                ?? Text(appKey: "account.kind." + provider.rawValue)
        )
        .toolbarTitleDisplayMode(.inline)
        .onAppear(perform: prefill)
        .sheet(item: $choiceAfterSignIn) { question in
            LibraryPickerSheet(
                identifier: question.identifier, libraries: question.libraries, title: question.title
            ) {
                choiceAfterSignIn = nil
                Task { await inventory.rebuild(question.identifier) }
                back()
            }
        }
        .task(id: state.account?.identifier) {
            guard state.phase == .signedIn, let source = accounts.source(slot),
                let list = try? await source.subLibraries(), list.count > 1
            else { return }
            libraries = list
        }
        .onDisappear {
            guard choiceChanged, let identifier = state.account?.identifier else { return }
            Task { await inventory.rebuild(identifier) }
        }
        .sheet(item: $certificate, onDismiss: afterCertificate) { question in
            CertificateQuestionView(question: question) { trusted in
                if trusted {
                    try? accounts.trust(question)
                    retry = true
                } else {
                    accounts.decline(question)
                    failure = .certificate(question)
                }
                certificate = nil
            }
        }
        .confirmationDialog(
            Text(app: "account.signOut.question"), isPresented: $signOutQuestion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task {
                    running = true
                    await accounts.signOut(slot)
                    running = false
                    if AccountSlot.multiple(provider) { back() }
                }
            } label: {
                Text(app: "account.signOut")
            }
        } message: {
            Text(app: "account.signOut.text")
        }
    }

    // MARK: - Profile card

    @ViewBuilder
    private func profileCard(_ entry: AccountEntry) -> some View {
        Section {
            LabeledContent {
                // For an OPDS catalog and a WebDAV folder the path matters
                // ("comics.example/opds/v1.2/catalog"); for servers it is the host name.
                Text(verbatim: SignInView.addressText(entry.account.server, provider: provider))
            } label: {
                Text(appKey: SignInView.addressKey(provider))
            }
            if !entry.account.username.isEmpty {
                LabeledContent {
                    Text(verbatim: entry.account.username)
                } label: {
                    Text(app: provider == .komga ? "account.email" : "account.name")
                }
            }
            LabeledContent {
                HStack(spacing: 6) {
                    Circle().fill(AccountRow.color(state.phase)).frame(width: 10, height: 10)
                    Text(appKey: state.phase.messageKey)
                }
            } label: {
                Text(app: "account.status")
            }
        }
        catalog(entry.account.identifier)
        libraryChoice(entry.account.identifier)
        Section {
            LabeledContent {
                Text(entry.createdAt, format: .dateTime.day().month().year())
            } label: {
                Text(app: "account.key.created")
            }
            LabeledContent {
                Text(verbatim: entry.device)
            } label: {
                Text(app: "account.key.device")
            }
        } footer: {
            if !entry.account.mayKeep {
                Text(app: "account.rights.noKeep")
            }
        }
        Section {
            Button {
                Task {
                    running = true
                    await accounts.verify(slot)
                    running = false
                    checked = Date()
                    Haptics.selection()
                }
            } label: {
                HStack {
                    Text(app: "account.check")
                    if running { Spacer(); ProgressView() }
                }
            }
            .disabled(running)
            // A child profile signs nothing out.
            if !profile.kind {
                Button(role: .destructive) {
                    signOutQuestion = true
                } label: {
                    Text(app: "account.signOut")
                }
                .disabled(running)
            }
        } footer: {
            if let checked {
                Text(
                    verbatim: Phrase.from(
                        "account.checked", checked.formatted(date: .omitted, time: .shortened),
                        Phrase.from(state.phase.messageKey)))
            }
        }
    }

    // MARK: - Catalog

    /// What the app knows of this server, when it last checked, and the two ways to help
    /// along: "Sync now" fetches the changes, "Rebuild" everything, for when something
    /// looks wrong.
    @ViewBuilder
    private func catalog(_ identifier: SourceID) -> some View {
        if let state = inventory.catalogRevision(identifier) {
            Section {
                LabeledContent {
                    Text(verbatim: Formats.integer(state.title)).monospacedDigit()
                } label: {
                    Text(app: "account.catalog.title")
                }
                LabeledContent {
                    Text(state.state, format: .relative(presentation: .named))
                } label: {
                    Text(app: "account.catalog.synced")
                }
                Button {
                    Task {
                        reconciling = true
                        await inventory.refresh()
                        reconciling = false
                        Haptics.selection()
                    }
                } label: {
                    HStack {
                        Text(app: "account.catalog.sync")
                        if reconciling { Spacer(); ProgressView() }
                    }
                }
                .disabled(reconciling)
                Button {
                    newQuestion = true
                } label: {
                    HStack {
                        Text(app: "account.catalog.new")
                        if builds { Spacer(); ProgressView() }
                    }
                }
                .disabled(reconciling)
                // Reloading everything takes long for big libraries, so it must not happen by accident.
                .confirmationDialog(
                    Text(app: "account.catalog.new.question"), isPresented: $newQuestion,
                    titleVisibility: .visible
                ) {
                    Button {
                        Task {
                            reconciling = true
                            builds = true
                            await inventory.rebuild(identifier)
                            builds = false
                            reconciling = false
                            Haptics.selection()
                        }
                    } label: {
                        Text(app: "account.catalog.new")
                    }
                } message: {
                    Text(app: "account.catalog.text")
                }
            } header: {
                Text(app: "account.catalog.header")
            } footer: {
                Text(app: "account.catalog.text")
            }
        }
    }

    @ViewBuilder
    private func libraryChoice(_ identifier: SourceID) -> some View {
        if !libraries.isEmpty {
            Section {
                LibraryPickerList(identifier: identifier, libraries: libraries) {
                    choiceChanged = true
                }
            } header: {
                Text(app: "libraryPicker.header")
            } footer: {
                Text(app: "libraryPicker.account.text")
            }
        }
    }

    /// After sign-in: if the server has several libraries and more than
    /// `LibraryPicker.ask` titles, ask which ones go into the app; otherwise nothing.
    private func askForChoice() async -> ChoiceQuestion? {
        guard let source = accounts.source(slot),
            let list = try? await source.subLibraries(), list.count > 1,
            let title = try? await source.titleCount(), title > LibraryPicker.ask
        else { return nil }
        return ChoiceQuestion(identifier: source.identifier, libraries: list, title: title)
    }

    // MARK: - Form

    @ViewBuilder
    private var formView: some View {
        Section {
            if provider == .opds {
                Picker(selection: $template) {
                    ForEach(OpdsTemplate.allCases) { v in
                        Text(appKey: v.lookupKey).tag(v)
                    }
                } label: {
                    Text(app: "account.opds.template")
                }
                .pickerStyle(.menu)
            }
            TextField(
                text: $address,
                prompt: Text(appKey: SignInView.addressKey(provider) + ".hinweis")
            ) {
                Text(appKey: SignInView.addressKey(provider))
            }
            .addressField()
            TextField(text: $name) {
                Text(app: provider == .komga ? "account.email" : "account.name")
            }
            .nameField(email: provider == .komga)
            SecureField(text: $password) {
                Text(app: "account.password")
            }
            .onSubmit(signInIfPossible)
        } header: {
            if state.entry != nil {
                Text(app: "account.signInAgain")
            }
        } footer: {
            if let failure {
                Text(appKey: failure.messageKey)
                    .foregroundStyle(ColorTheme.failure.color)
            } else if provider == .opds, let path = template.path {
                Text(verbatim: Phrase.from("account.opds.template.hinweis", path))
            } else if provider == .opds {
                Text(app: "account.opds.hint")
            } else if provider == .webdav {
                Text(app: "account.webdav.hint")
            } else if provider == .kavita {
                Text(app: "account.kavita.hint")
            }
        }
        Section {
            Button(action: signInIfPossible) {
                HStack {
                    Text(app: "account.signIn")
                    if running {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(running || !complete)
        }
    }

    /// An OPDS catalog or a WebDAV folder may be open; name and password are optional
    /// there.
    private var complete: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
            && (SignInView.withPath(provider) || (!name.isEmpty && !password.isEmpty))
    }

    /// For OPDS and WebDAV the address is a path (catalog, folder); for the servers it is a
    /// host name.
    static func withPath(_ provider: Provider) -> Bool { provider == .opds || provider == .webdav }

    /// The key of the address field: "Catalog address", "Folder address", "Address".
    static func addressKey(_ provider: Provider) -> String {
        switch provider {
        case .opds: "account.catalog"
        case .webdav: "account.folder"
        default: "account.address"
        }
    }

    /// "comics.example" for the servers; "comics.example/opds/v1.2/catalog" for the catalog,
    /// "nextcloud.example/remote.php/dav/files/.../Books" for the folder: readable, not encoded.
    static func addressText(_ url: URL, provider: Provider) -> String {
        guard withPath(provider) else { return url.host() ?? url.absoluteString }
        var text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        for schema in ["https://", "http://"] where text.hasPrefix(schema) {
            if schema == "https://" { text.removeFirst(schema.count) }
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// A suggestion from the setup code or, for an expired account, what is already there;
    /// the user then only types the password.
    private func prefill() {
        let suggestion = accounts.suggested[provider]
        if address.isEmpty {
            address =
                (suggestion?.address ?? state.account?.server).map {
                    SignInView.addressText($0, provider: provider)
                }
                ?? ""
        }
        if name.isEmpty {
            name = suggestion?.name ?? state.account?.username ?? ""
        }
        if failure == nil {
            failure = accounts.lastError[provider]
        }
    }

    private func signInIfPossible() {
        guard complete, !running else { return }
        Task { await signIn() }
    }

    private func signIn() async {
        running = true
        failure = nil
        defer { running = false }
        do {
            let target =
                provider == .opds ? OpdsTemplate.catalogAddress(address, template: template) : address
            try await accounts.signIn(slot, address: target, name: name, password: password)
            password = ""
            if let question = await askForChoice() {
                choiceAfterSignIn = question
            } else {
                back()
            }
        } catch {
            if case .certificate(let question) = error {
                certificate = question
            } else {
                failure = error
            }
        }
    }

    /// After the certificate sheet: if the fingerprint is now stored, sign in again right
    /// away so nobody has to tap "Sign in" twice. Only after the sheet has closed, not in
    /// the button: a second sheet over one that is just leaving gets stuck.
    private func afterCertificate() {
        guard retry else { return }
        retry = false
        signInIfPossible()
    }
}

extension View {

    /// A field for a server address: no capitalization, no autocorrection, keyboard with
    /// period and slash where one exists.
    fileprivate func addressField() -> some View {
        #if os(iOS)
            return self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .textContentType(.URL)
        #else
            return self.autocorrectionDisabled()
        #endif
    }

    fileprivate func nameField(email: Bool) -> some View {
        #if os(iOS)
            return self.textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(email ? .emailAddress : .default).textContentType(
                    email ? .emailAddress : .username)
        #else
            return self.autocorrectionDisabled().textContentType(.username)
        #endif
    }
}
