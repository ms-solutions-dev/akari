import AccountsKit
import DesignSystem
import Library
import NetworkLocation
import SwiftUI

/// The disruption in place: a banner at the top of the affected area, for example
/// "Manga: unreachable · Status from yesterday 21:14 · Try again · Check account".
/// No separate tab, no alarm: whoever does not read it sees nothing.
///
/// **Four disruptions, three paths:** a server that is down or answers 5xx gets the age of
/// its cache added, since the shelf is still there, just older. An expired account (401)
/// gets "Check account" highlighted, since waiting does not help. A changed certificate
/// gets "Check certificate", which asks the question with the fingerprint; it is not
/// "unreachable", because the network is up and the watcher aborted.
struct DisruptionBanner: View {

    @Environment(AccountRegistry.self) private var accounts
    @Environment(LibraryService.self) private var inventory
    @Environment(NetworkWatch.self) private var network
    @Environment(\.accessibilityReduceMotion) private var calm
    @State private var account = false
    @State private var running = false

    /// One banner instead of four: without network the status banner says so alone; if all
    /// accounts are disrupted, "No server reachable" appears once; single disruptions each
    /// get their own banner.
    private var rows: [AccountRegistry.Status?] {
        if network.reported, !network.route.usable { return [] }
        let disruptions = accounts.disruptions
        let signedIn = accounts.states.filter { $0.account != nil }.count
        if disruptions.count > 1, disruptions.count == signedIn,
            disruptions.allSatisfy({ $0.phase == .unreachable || $0.phase == .disrupted })
        {
            return [nil]
        }
        return disruptions
    }

    var body: some View {
        let rows = self.rows
        ScanBanner()
            .animation(Motion.soft(calm), value: inventory.scanShow)
        if !rows.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, state in
                    Banner(
                        .disruption, level: state.flatMap { AccountRow.signal($0.phase) } ?? .failure,
                        text: state.map(phrase) ?? Text(app: "disruption.allGone")
                    ) {
                        if state?.phase == .certificate {
                            Button {
                                Task {
                                    running = true
                                    await accounts.verify()
                                    running = false
                                }
                            } label: {
                                Text(app: "disruption.certificate")
                            }
                            .disabled(running)
                        } else {
                            Button {
                                Task {
                                    running = true
                                    await accounts.verify()
                                    await inventory.refresh()
                                    running = false
                                }
                            } label: {
                                Text(app: "disruption.again")
                            }
                            .disabled(running)
                        }
                        Button {
                            account = true
                        } label: {
                            Text(app: "disruption.account")
                        }
                        if running { ProgressView() }
                    }
                }
            }
            .padding(.top, 8)
            .sheet(isPresented: $account) {
                AccountsView()
            }
        }
    }

    /// "Books: unreachable · Status from yesterday 21:14": kind and state come from the
    /// catalog, the status from the extract the source last delivered.
    private func phrase(_ state: AccountRegistry.Status) -> Text {
        let name =
            state.account?.displayName.map { Text(verbatim: $0) }
            ?? Text(appKey: "account.kind." + state.provider.rawValue)
        let phase = Text("\(name): \(Text(appKey: state.phase.messageKey))")
        guard state.phase == .unreachable || state.phase == .disrupted,
            let identifier = state.account?.identifier, let date = inventory.shelf.state(identifier)
        else { return phase }
        let age = Phrase.from(
            "start.state", date.formatted(.relative(presentation: .named)),
            date.formatted(date: .omitted, time: .shortened))
        return Text("\(phase) · \(Text(verbatim: age))")
    }
}

/// "Importing · 12,000 of 35,551 books" while a large source loads its catalog page by
/// page. Shown only after three seconds so a sync that finishes sooner does not flash. The
/// shelf stays usable meanwhile.
struct ScanBanner: View {

    @Environment(LibraryService.self) private var inventory
    @Environment(\.theme) private var theme

    var body: some View {
        let states = inventory.scan.values
        let loaded = states.reduce(0) { $0 + $1.loaded }
        let total = states.reduce(0) { $0 + $1.total }
        if inventory.scanShow, total > 0 {
            Banner(
                .hint,
                text: Text(
                    verbatim: Phrase.from("scan.banner", Formats.integer(loaded), Formats.integer(total)))
            ) {
                // The bar shows progress; the number alone does not say how far along it is.
                ProgressView(value: Double(loaded), total: Double(max(total, 1)))
                    .tint(theme.accent.color)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
