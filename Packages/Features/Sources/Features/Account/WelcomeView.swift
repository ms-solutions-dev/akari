import AccountsKit
import DesignSystem
import SourcesKit
import SwiftUI

/// The welcome flow: the same screen as the account sheet, with a different face.
///
/// Three rows (manga, books, audiobooks), each skippable, no carousel; below them
/// the two open routes, an OPDS catalog and a WebDAV folder, for everyone without the three
/// servers. Whoever has the code from the server scans it and afterwards only types name and
/// password per server. "Later" is allowed; Start then carries the button back here.
///
/// With the profile in the header: the first profile is named after the person in the
/// code (or after the device); a second profile comes here through "Who is reading?" and
/// signs in its own accounts; the per-person code works the same there.
///
/// The flow opens with a promise rather than a form: cover fan and worm, one sentence,
/// three routes: connect a server, own EPUB, sample shelf. Whoever arrives with a code
/// lands directly at the servers.
struct WelcomeView: View {

    @Environment(\.profile) private var profile
    @Environment(ProfileRegistry.self) private var profiles

    @Environment(AccountRegistry.self) private var accounts
    @Environment(AppCore.self) private var core
    @Environment(\.dismiss) private var close
    @State private var scanner = false
    @State private var path = NavigationPath()
    @State private var promise = true
    @Environment(\.horizontalSizeClass) private var width

    /// The promise only on a genuine first launch: first profile, no child profile,
    /// no account and no code from outside. A second profile ("Who is reading?") already
    /// knows the app and goes straight to the servers.
    private var showPromise: Bool {
        promise && !accounts.configured && accounts.suggested.isEmpty
            && profiles.all.count <= 1 && !profile.kind
    }

    var body: some View {
        if showPromise {
            WelcomePromise(
                connect: { promise = false },
                done: { close() })
        } else {
            setUp
        }
    }

    private var setUp: some View {
        NavigationStack(path: $path) {
            List {
                if accounts.configured {
                    // "All there." The worm cheers as soon as a server is connected.
                    Section {
                        HStack(spacing: 14) {
                            Worm(.cheer, edge: 72)
                            Text(app: "welcome.allPresent")
                                .font(Typography.title(.title3))
                                .foregroundStyle(ColorTheme.typography.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                // The code first, the parents' route; the manual forms below
                // for everyone without `einrichten.example`.
                Section {
                    HStack(spacing: 12) {
                        ProfileImage(profile: profile, size: 36)
                        Text(verbatim: Phrase.from("setUp.profile", profile.name))
                            .font(Typography.name(.subheadline))
                    }
                    Text(app: "setUp.text")
                    Button {
                        scanner = true
                    } label: {
                        Label(app: "setUp.code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(app: "setUp.code.text")
                }
                Section {
                    ForEach(accounts.states.filter { !AccountSlot.multiple($0.provider) }) { state in
                        NavigationLink(value: state.slot) {
                            AccountRow(
                                state: state, suggestion: accounts.suggested[state.provider],
                                failure: accounts.lastError[state.provider])
                        }
                    }
                } header: {
                    Text(app: "welcome.orByHand")
                }
                // Catalog and folder side by side: the routes for Calibre-Web
                // and for the Nextcloud folder full of EPUBs.
                Section {
                    ForEach(accounts.catalogs + accounts.folder) { state in
                        NavigationLink(value: state.slot) {
                            AccountRow(state: state)
                        }
                    }
                    NavigationLink(value: accounts.newSlot(.opds)) {
                        Label(app: "account.catalog.add", systemImage: "plus.circle")
                    }
                    NavigationLink(value: accounts.newSlot(.webdav)) {
                        Label(app: "account.folder.add", systemImage: "plus.circle")
                    }
                } header: {
                    Text(app: "welcome.more")
                }
                BulkSignIn()
            }
            // iPad: a centered 540 pt card instead of a stretched form.
            .frame(maxWidth: width == .regular ? 540 : .infinity)
            .frame(maxWidth: .infinity)
            .paper()
            .navigationDestination(for: AccountSlot.self) { slot in
                // The same 540 pt card as the list before it.
                SignInView(slot: slot)
                    .frame(maxWidth: width == .regular ? 540 : .infinity)
                    .frame(maxWidth: .infinity)
                    .paper()
            }
            .navigationTitle(Text(app: "setUp.title"))
            .sharingQuestions(core.questions)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        close()
                    } label: {
                        Text(app: accounts.configured ? "setUp.done" : "setUp.later")
                    }
                }
            }
            .sheet(isPresented: $scanner, onDismiss: toSuggestion) {
                CodeScannerView()
            }
            .onAppear(perform: toSuggestion)
            // The link from outside can arrive while the sheet is already open.
            .onChange(of: accounts.suggested) { _, _ in toSuggestion() }
        }
    }

    /// After the code (from the camera or via the link from outside), go straight to the
    /// first sign-in sheet; otherwise the list looks unchanged.
    private func toSuggestion() {
        // If the code carries names for several accounts, the list stays: "One password
        // for all" sits right below it, and the single sheet used to cover it.
        guard accounts.collectible.count < 2 else { return }
        guard path.isEmpty else { return }
        if let first = accounts.states.first(where: {
            $0.account == nil && accounts.suggested[$0.provider] != nil
        }) {
            path.append(first.slot)
        } else if let unresolved = [Provider.opds, .webdav].first(where: { accounts.suggested[$0] != nil }) {
            path.append(accounts.newSlot(unresolved))
        }
    }
}

/// The first step of the welcome flow: a fan of three covers with the worm in front,
/// the promise in one sentence, the routes below. The covers are invented titles as
/// ``TitlePlaceholder``, since the app has none on first launch.
private struct WelcomePromise: View {

    let connect: () -> Void
    let done: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.importFile) private var importFile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fanned = false
    @State private var filePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                fan
                    .frame(height: 290)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                Text(app: "welcome.promise.title")
                    .font(Typography.title(.largeTitle))
                    .foregroundStyle(ColorTheme.typography.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(app: "welcome.promise.text")
                    .font(.body)
                    .foregroundStyle(ColorTheme.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 12) {
                    Button(action: connect) {
                        Text(app: "welcome.promise.connect").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    Button {
                        filePicker = true
                    } label: {
                        Text(app: "welcome.promise.epub").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondary)
                    if SampleShelf.present {
                        Button {
                            // Close first, then import: the import notice hangs on
                            // the shell beneath this sheet and would otherwise be lost.
                            done()
                            importFile(SampleShelf.files)
                        } label: {
                            Text(app: "welcome.promise.examples")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: TapTarget.atLeast)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background {
            // The glow from the design system, here without a cover yet: the accent as a halo.
            ZStack {
                theme.paper.color
                RadialGradient(
                    colors: [theme.accent.color.opacity(0.18), .clear], center: UnitPoint(x: 0.5, y: 0.2),
                    startRadius: 20, endRadius: 380)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            Button(action: done) {
                Text(app: "setUp.later")
                    .font(.subheadline.weight(.medium))
                    .frame(minWidth: TapTarget.atLeast, minHeight: TapTarget.atLeast)
            }
            .padding(.trailing, 12)
        }
        .fileImporter(
            isPresented: $filePicker, allowedContentTypes: FileType.all, allowsMultipleSelection: true
        ) {
            result in
            if case .success(let urls) = result, !urls.isEmpty {
                done()
                importFile(urls)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.8).delay(0.05)) {
                fanned = true
            }
        }
    }

    /// Three covers that fan out on appearing; the worm tips its hat in front.
    private var fan: some View {
        ZStack {
            cover("Frankenstein", "Mary Shelley")
                .rotationEffect(.degrees(fanned ? -11 : 0))
                .offset(x: fanned ? -78 : 0, y: fanned ? 16 : 0)
            cover("Alice's Adventures in Wonderland", "Lewis Carroll")
                .rotationEffect(.degrees(fanned ? 10 : 0))
                .offset(x: fanned ? 78 : 0, y: fanned ? 14 : 0)
            cover("The Time Machine", "H. G. Wells")
                .scaleEffect(1.06)
            Worm(.welcome, edge: 112)
                .offset(x: 88, y: 92)
                .scaleEffect(fanned ? 1 : 0.6, anchor: .bottom)
                .opacity(fanned ? 1 : 0)
        }
        .accessibilityHidden(true)
    }

    private func cover(_ title: String, _ author: String) -> some View {
        TitlePlaceholder(title: title, author: author)
            .frame(width: 132, height: 198)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            // Contact shadow and soft ambient shadow: covers are objects.
            .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
    }
}
