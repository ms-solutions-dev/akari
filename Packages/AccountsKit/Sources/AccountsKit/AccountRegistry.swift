import Bedrock
import Foundation
import Observation
import SourcesKit

/// The accounts with state — what the accounts sheet shows and what the library
/// asks: three servers with one slot each, plus any number of OPDS catalogs and
/// WebDAV folders.
///
/// Main-actor bound because the screens depend on it; the network work runs in the
/// sources. Holds exactly one entry per provider and builds the source from it, once —
/// Grimmory's access guard lives in the source, and whoever rebuilds it on every call
/// refreshes on every call.
@MainActor
@Observable
public final class AccountRegistry {

    /// One row in the accounts sheet.
    public struct Status: Sendable, Hashable, Identifiable {
        public let slot: AccountSlot
        public var entry: AccountEntry?
        public var phase: AccountState
        public var id: AccountSlot { slot }
        public var provider: Provider { slot.provider }

        public var account: Account? { entry?.account }

        public init(
            slot: AccountSlot, entry: AccountEntry? = nil, phase: AccountState = .notConfigured
        ) {
            self.slot = slot
            self.entry = entry
            self.phase = phase
        }
    }

    /// The rows, in tab-bar order: manga, books, audiobooks — then the OPDS catalogs, as
    /// many as were created.
    public private(set) var states: [Status]

    /// What a setup code brings for an account: the address, and for a per-person code
    /// also the name. The form takes both; with names for all open accounts a single
    /// password field is enough (``signInAll(password:)``).
    public struct Suggestion: Sendable, Hashable {
        public let address: URL
        public let name: String?

        public init(address: URL, name: String? = nil) {
            self.address = address
            self.name = name
        }
    }

    /// Suggestions from a setup code that are still waiting for their sign-in.
    public private(set) var suggested: [Provider: Suggestion] = [:]

    /// What the last sign-in per account failed on — for the row after a bulk sign-in
    /// where two succeeded and one did not.
    public private(set) var lastError: [Provider: SignInError] = [:]

    /// The certificate question that came up while checking a signed-in account — the
    /// shell presents it as a sheet (before, only the sign-in form read the mailbox, and
    /// a changed certificate on a running account silently read "unreachable").
    /// ``trust(_:)`` and ``decline(_:)`` clear it; the row stays at
    /// ``AccountState/certificate`` until a check goes through.
    public private(set) var certificateQuestion: CertificateQuestion.Unresolved?

    private let persistence: AccountStore
    private let factory: SourceFactory
    private let trusts: CertificateTrustStore
    private let questions: CertificateQuestion
    private let deviceName: String
    private var sources: [AccountSlot: any Source] = [:]

    /// - Parameter questions: The mailbox the certificate guard writes to — `.shared` in
    ///   production, one per test in tests.
    /// - Parameter states: The folder of the local reading states (OPDS, WebDAV) — the
    ///   profile's; without `factory` it goes into the standard factory.
    public init(
        persistence: AccountStore = AccountStore(), trusts: CertificateTrustStore = CertificateTrustStore(),
        factory: SourceFactory? = nil, questions: CertificateQuestion = .shared,
        deviceName: String = DeviceName.thisDevice, states: URL? = nil
    ) {
        self.persistence = persistence
        self.trusts = trusts
        self.factory = factory ?? .standard(trusts: trusts, states: states)
        self.questions = questions
        self.deviceName = deviceName
        let stored = persistence.all()
        var states: [Status] = []
        for provider in Provider.server {
            if AccountSlot.multiple(provider) {
                for slot in persistence.slots(provider) {
                    states.append(Status(slot: slot, entry: stored[slot], phase: .unchecked))
                }
            } else {
                let slot = AccountSlot.server(provider)
                states.append(
                    Status(
                        slot: slot, entry: stored[slot],
                        phase: stored[slot] == nil ? .notConfigured : .unchecked))
            }
        }
        self.states = states
    }

    // MARK: - Reading

    /// The row of a server — the three always have one.
    public func state(_ provider: Provider) -> Status {
        states.first { $0.provider == provider } ?? Status(slot: .server(provider))
    }

    /// The row of a slot — `nil` for an OPDS slot that has not been created yet.
    public func state(_ slot: AccountSlot) -> Status? {
        states.first { $0.slot == slot }
    }

    /// The OPDS catalogs, in order of their number.
    public var catalogs: [Status] { states.filter { $0.provider == .opds } }

    /// The WebDAV folders, in order of their number.
    public var folder: [Status] { states.filter { $0.provider == .webdav } }

    /// The next free slot for another catalog.
    public func newSlot(_ provider: Provider) -> AccountSlot {
        guard AccountSlot.multiple(provider) else { return .server(provider) }
        let taken = states.filter { $0.provider == provider }.map(\.slot.number)
        return AccountSlot(provider, number: (taken.max() ?? -1) + 1)
    }

    /// Whether at least one account exists — otherwise the welcome flow.
    public var configured: Bool { states.contains { $0.entry != nil } }

    /// The red dot on the account button.
    public var needsAttention: Bool { states.contains { $0.phase.needsAttention } }

    /// What is currently not working — for the banner in the section.
    public var disruptions: [Status] { states.filter { $0.phase.disrupted } }

    /// The source for a slot, built once and then kept.
    public func source(_ slot: AccountSlot) -> (any Source)? {
        if let q = sources[slot] { return q }
        guard let account = state(slot)?.account else { return nil }
        let q = factory.source(account) { [weak self] new in
            Task { @MainActor in self?.renew(new) }
        }
        sources[slot] = q
        return q
    }

    public func source(_ provider: Provider) -> (any Source)? {
        source(.server(provider))
    }

    /// All signed-in sources — what `Library` sums up.
    public var allSources: [any Source] {
        states.compactMap { source($0.slot) }
    }

    /// The transport of a provider — for covers and pages that do not run through the
    /// kit but need the same session with the same certificate guard.
    public nonisolated func transport(_ provider: Provider) -> any Transport {
        factory.transport(provider)
    }

    // MARK: - Signing in and out

    /// Signs in and puts the account into the keychain. Throws one of the speaking
    /// errors; for the certificate it carries the question to ask.
    public func signIn(
        _ provider: Provider, address: String, name: String, password: String
    ) async throws(SignInError) {
        try await signIn(newSlotOrServer(provider), address: address, name: name, password: password)
    }

    /// A server's own slot; for OPDS a new one — unless a catalog already exists at the
    /// same address (then that one is renewed).
    private func newSlotOrServer(_ provider: Provider) -> AccountSlot {
        AccountSlot.multiple(provider) ? newSlot(provider) : .server(provider)
    }

    /// Signs in on a slot — a new OPDS slot gets its row along the way.
    public func signIn(
        _ slot: AccountSlot, address: String, name: String, password: String
    ) async throws(SignInError) {
        let provider = slot.provider
        guard let server = ServerAddress.url(from: address) else { throw .address }
        // A leftover question from another attempt must not count as the answer to this
        // one.
        questions.clearOut()
        let account: Account
        do {
            account = try await factory.signIn(
                provider, server: server, name: name, password: password, deviceName: deviceName)
        } catch {
            throw SignInError.from(error, host: server.host() ?? "", questions: questions)
        }
        let entry = AccountEntry(account: account, device: deviceName)
        do { try persistence.persist(entry, on: slot) } catch { throw .persistence }
        sources[slot] = nil
        suggested[provider] = nil
        lastError[provider] = nil
        if state(slot) == nil {
            states.append(Status(slot: slot, entry: entry, phase: .signedIn))
            states.sort {
                ($0.provider.order, $0.slot.number) < ($1.provider.order, $1.slot.number)
            }
        } else {
            set(slot) {
                $0.entry = entry; $0.phase = .signedIn
            }
        }
    }

    /// The accounts that have a suggestion with a name and nobody signed in yet — the
    /// bulk sign-in applies to exactly these.
    public var collectible: [Provider] {
        states.filter { $0.account == nil && suggested[$0.provider]?.name != nil }.map(\.provider)
    }

    /// One password for all open accounts with names — side by side, not one after the
    /// other. What fails stays open and is listed in ``lastError``; the return value is
    /// what succeeded.
    @discardableResult
    public func signInAll(password: String) async -> [Provider] {
        let targets = collectible
        var succeeded: [Provider] = []
        await withTaskGroup(of: (Provider, SignInError?).self) { group in
            for provider in targets {
                guard let v = suggested[provider], let name = v.name else { continue }
                group.addTask {
                    do {
                        try await self.signIn(
                            provider, address: v.address.absoluteString, name: name, password: password)
                        return (provider, nil)
                    } catch let failure as SignInError {
                        return (provider, failure)
                    } catch {
                        return (provider, .unreachable)
                    }
                }
            }
            for await (provider, failure) in group {
                if let failure { lastError[provider] = failure } else { succeeded.append(provider) }
            }
        }
        return succeeded
    }

    /// Forgets the account here and — for Komga — the key on the server. If the server
    /// is unreachable the key stays there; the account is gone anyway.
    public func signOut(_ provider: Provider) async {
        await signOut(.server(provider))
    }

    /// A server becomes an empty row; an OPDS catalog disappears from the sheet.
    public func signOut(_ slot: AccountSlot) async {
        if let account = state(slot)?.account {
            try? await factory.signOut(account)
        }
        try? persistence.remove(slot)
        sources[slot] = nil
        if AccountSlot.multiple(slot.provider) {
            states.removeAll { $0.slot == slot }
        } else {
            set(slot) {
                $0.entry = nil; $0.phase = .notConfigured
            }
        }
    }

    // MARK: - Verifying

    /// Asks every signed-in server once — side by side, not one after the other; a
    /// sleeping server must not hold up the other two for 30 s.
    public func verify() async {
        await withTaskGroup(of: Void.self) { group in
            for state in states where state.entry != nil {
                group.addTask { await self.verify(state.slot) }
            }
        }
    }

    public func verify(_ provider: Provider) async {
        await verify(.server(provider))
    }

    public func verify(_ slot: AccountSlot) async {
        guard let source = source(slot), let account = state(slot)?.account else { return }
        let phase: AccountState
        do {
            try await source.verify()
            phase = .signedIn
        } catch {
            phase = AccountState.from(error, host: account.server.host() ?? "", questions: questions)
            Diagnostics.network.error(
                "\(slot.description, privacy: .public): verification \(String(describing: phase), privacy: .public)"
            )
        }
        if phase == .certificate, let unresolved = questions.present { certificateQuestion = unresolved }
        set(slot) { $0.phase = phase }
    }

    // MARK: - Certificate and setup code

    /// Trusts the presented certificate for this host and clears the question. The next
    /// sign-in attempt goes through.
    public func trust(_ question: CertificateQuestion.Unresolved) throws {
        try trusts.trust(question.fingerprint, for: question.host)
        questions.respond(question)
        if certificateQuestion == question { certificateQuestion = nil }
    }

    public func decline(_ question: CertificateQuestion.Unresolved) {
        questions.respond(question)
        if certificateQuestion == question { certificateQuestion = nil }
    }

    /// The slots whose server is this host — after a confirmed certificate exactly
    /// these are re-checked.
    public func slots(for host: String) -> [AccountSlot] {
        states.filter { $0.account?.server.host()?.caseInsensitiveCompare(host) == .orderedSame }.map(\.slot)
    }

    /// Adopts a setup code: trusts the fingerprint for every host in it and remembers
    /// the addresses as suggestions for the forms. Signing in happens per server with
    /// name and password — the code carries none.
    public func adopt(_ code: SetupCode) {
        if let snapshot = code.fingerprint {
            for computer in code.computer {
                try? trusts.trust(snapshot, for: computer)
            }
        }
        for (provider, address) in code.server where state(provider).entry == nil {
            suggested[provider] = Suggestion(address: address, name: code.names[provider])
            lastError[provider] = nil
        }
    }

    /// The setup code of this profile for another device ("Add device") — see
    /// ``SetupCode/from(accounts:trusts:person:color:sharing:)``.
    public func setupCode(person: String, color: String?, sharing: URL?) -> SetupCode {
        SetupCode.from(
            accounts: persistence.all(), trusts: trusts, person: person, color: color, sharing: sharing)
    }

    // MARK: - Helpers

    private func set(_ slot: AccountSlot, _ mutation: (inout Status) -> Void) {
        guard let i = states.firstIndex(where: { $0.slot == slot }) else { return }
        mutation(&states[i])
    }

    /// A renewed account (Grimmory's token pair) — into the keychain and into the row,
    /// without rebuilding the source.
    private func renew(_ account: Account) {
        guard let state = states.first(where: { $0.account?.identifier == account.identifier }),
            var entry = state.entry
        else { return }
        entry.account = account
        try? persistence.persist(entry, on: state.slot)
        set(state.slot) { $0.entry = entry }
    }
}

extension Provider {
    /// The order in the accounts sheet — as in `Provider.server`.
    var order: Int { Provider.server.firstIndex(of: self) ?? Provider.server.count }
}
