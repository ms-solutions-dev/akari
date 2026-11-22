import AccountsKit
import Bedrock
import CloudSync
import DesignSystem
import Library
import ReadingProgress
import SwiftUI

/// "iCloud & Devices": everything about a profile's zone in one place.
///
/// 1. **Content:** what is in iCloud ("312 sessions, 14 saved entries, theme, as of
///    00:09"), the **Sync via iCloud** switch per profile (off means local only, no
///    zone), **Export** (the mirror as JSON via the share sheet) and **Remove from
///    iCloud** (delete the zone, data stays here, sync off, with confirmation).
/// 2. **Owner:** the participants of the share from `CKShare.participants` with
///    permissions and acceptance status, a Remove action per row and "End sharing" at
///    the bottom; plus the app's own **device list**: every device that uses the zone
///    registers itself as a `Geraet` record. The footnote says honestly what Apple
///    knows: only Apple IDs as participants. A device is removed via its Apple ID, and
///    two devices on the same ID cannot be told apart.
/// 3. **Participant:** "Shared by ..." with **Leave sharing**, after which the profile
///    disappears together with its local copy; the participant sees the device list too.
///
/// **Who is who:** for a share via link, Apple does not reveal a participant's
/// identity, and the row used to say "Unknown account". Now it shows the
/// **participant's devices** (the `Geraet` records their Apple ID created,
/// `___createdBy`), and devices and participants can be **renamed**: a tap on the row,
/// a text field with the current name. The device name is stored in the `Geraet`
/// record (with `benannt`, so the device does not overwrite it with its system name),
/// the participant name as a `Profileinstellung` `teilnehmer.<Apple-ID>`. The sheet
/// syncs once on open.
///
/// Apple's levers (iCloud off for the app, account signed out) arrive as
/// `CKAccountChanged` at the hub; the section says so, nothing hangs.
///
/// The **active** profile's zone is the context's; for another profile the sheet opens
/// the mirror on disk only to read and sync (`unprompted: false`), and nobody writes
/// there while the profile is not active.
struct ProfileCloudView: View {

    let profile: Profile

    @Environment(AppCore.self) private var core
    @Environment(ProfileRegistry.self) private var profiles
    @Environment(\.theme) private var theme
    @State private var zone: ProfileZone?
    @State private var sharing: Sharing?
    @State private var running = false
    @State private var failure: String?
    @State private var removeQuestion = false
    @State private var finishQuestion = false
    @State private var leaveQuestion = false
    @State private var export: URL?
    /// What is being renamed, device or participant, and the name in the field.
    @State private var renaming: Renaming?
    @State private var newName = ""

    enum Renaming: Identifiable {
        case device(DeviceEntry)
        case participant(Participant)

        var id: String {
            switch self {
            case .device(let g): "geraet-" + g.identifier
            case .participant(let t): "teilnehmer-" + t.identifier
            }
        }
    }

    /// The profile's current state from the registry; the switch changes it.
    private var current: Profile { profiles.all.first { $0.id == profile.id } ?? profile }
    private var active: Bool { core.context.profile.id == profile.id }

    var body: some View {
        List {
            content
            if current.shared {
                participantPage
                devices
            } else if current.cloudSync, current.cloud != nil {
                devices
                sharingSection
            }
        }
        .paper()
        .navigationTitle(Text(app: "cloud.title"))
        .toolbarTitleDisplayMode(.inline)
        .task(id: current.cloud) { await load() }
        .onAppear { core.sameCloudSince() }
        .alert(
            Text(app: "cloud.rename"),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { was in
            TextField(text: $newName) { Text(app: "cloud.rename.name") }
            Button {
                rename(was, newName)
            } label: {
                Text(app: "action.done")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "action.cancel")
            }
        } message: { was in
            switch was {
            case .device: Text(app: "cloud.rename.device.text")
            case .participant: Text(app: "cloud.rename.participant.text")
            }
        }
        .confirmationDialog(
            Text(app: "cloud.remove.question"), isPresented: $removeQuestion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await switchTo(false) }
            } label: {
                Text(app: "cloud.remove")
            }
        } message: {
            Text(app: "cloud.remove.text")
        }
        .confirmationDialog(
            Text(app: "cloud.sharing.finish.question"), isPresented: $finishQuestion,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await endSharing() }
            } label: {
                Text(app: "cloud.sharing.finish")
            }
        } message: {
            Text(app: "cloud.sharing.finish.text")
        }
        .confirmationDialog(
            Text(app: "cloud.leave.question"), isPresented: $leaveQuestion, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await leave() }
            } label: {
                Text(app: "cloud.leave")
            }
        } message: {
            Text(app: "cloud.leave.text")
        }
        .alert(
            Text(app: "profile.error"),
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button {
                failure = nil
            } label: {
                Text(app: "action.ok")
            }
        } message: {
            Text(verbatim: failure ?? "")
        }
    }

    // MARK: - Content

    private var content: some View {
        Section {
            LabeledContent {
                Text(verbatim: accountRow)
                    .foregroundStyle(ColorTheme.muted.color)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text(app: "cloud.account")
            }
            if !current.shared {
                Toggle(
                    isOn: Binding(
                        get: { current.cloudSync }, set: { new in Task { await switchTo(new) } })
                ) {
                    Text(app: "cloud.sync")
                }
                .disabled(running)
            }
            if current.cloudSync, let zone {
                Text(verbatim: contentRow(zone))
                    .font(.footnote)
                    .foregroundStyle(ColorTheme.muted.color)
                Button {
                    Task { await zone.equalSince() }
                } label: {
                    Label(app: "statistics.cloud.sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(zone.zone == nil || core.cloud.account != .available)
                if let export {
                    ShareLink(item: export) {
                        Label(app: "cloud.export", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        exportZone(zone)
                    } label: {
                        Label(app: "cloud.export", systemImage: "square.and.arrow.up")
                    }
                }
                if !current.shared, zone.zone != nil {
                    Button(role: .destructive) {
                        removeQuestion = true
                    } label: {
                        Label(app: "cloud.remove", systemImage: "icloud.slash")
                    }
                }
            }
        } header: {
            Text(app: "cloud.part")
        } footer: {
            Text(app: current.cloudSync ? "cloud.sync.text" : "cloud.sync.off.text")
        }
    }

    /// "Account present, as of 00:09" / "no iCloud account" / "unreachable, 3 waiting".
    private var accountRow: String {
        switch core.cloud.account {
        case .noAccount: return Phrase.from("cloud.account.none")
        case .restricted: return Phrase.from("cloud.account.restricted")
        case .unknown: return Phrase.from("cloud.account.unknown")
        case .available: break
        }
        guard let zone, current.cloudSync else { return Phrase.from("cloud.account.local") }
        return CloudRow.state(zone)
    }

    private func contentRow(_ zone: ProfileZone) -> String {
        var share: [String] = []
        share.append(Phrase.from("cloud.content.sessions", zone.count(ReadingTimeLog.type)))
        share.append(Phrase.from("cloud.content.savedEntries", zone.count(SavedList.type)))
        if zone.record(type: CloudHub.settingType, name: ThemeChoice.recordName) != nil {
            share.append(Phrase.from("cloud.content.theme"))
        }
        let state = zone.recently.map {
            Phrase.from("cloud.content.state", $0.formatted(date: .omitted, time: .shortened))
        }
        return Phrase.from("cloud.content", share.joined(separator: ", ")) + (state.map { " — " + $0 } ?? "")
    }

    // MARK: - Devices and sharing (owner)

    private var devices: some View {
        Section {
            if let zone {
                let list = CloudHub.devices(in: zone)
                if list.isEmpty {
                    Text(app: "cloud.devices.empty").foregroundStyle(ColorTheme.muted.color)
                }
                ForEach(list) { device in
                    Button {
                        startRenaming(.device(device), name: device.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(verbatim: device.name)
                                if device.identifier == core.cloud.device.identifier {
                                    Text(app: "cloud.device.this")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(
                                verbatim: device.model + " · "
                                    + Phrase.from(
                                        "cloud.device.recently",
                                        device.recently.formatted(date: .abbreviated, time: .shortened))
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            startRenaming(.device(device), name: device.name)
                        } label: {
                            Label(app: "cloud.rename", systemImage: "pencil")
                        }
                    }
                }
            }
        } header: {
            Text(app: "cloud.devices")
        } footer: {
            Text(app: "cloud.devices.text")
        }
    }

    private func startRenaming(_ was: Renaming, name: String) {
        newName = name
        renaming = was
    }

    /// Writes the new name into the zone: a device as `Geraet.name` with `benannt`, a
    /// participant as `Profileinstellung`; the sync follows by itself.
    private func rename(_ was: Renaming, _ name: String) {
        guard let zone else { return }
        switch was {
        case .device(let device): core.cloud.renameDevice(device.identifier, name: name, in: zone)
        case .participant(let t): core.cloud.renameParticipant(t.identifier, name: name, in: zone)
        }
        if !active { Task { await zone.equalSince() } }
        Haptics.success()
    }

    private var sharingSection: some View {
        Section {
            NavigationLink(value: AccountTarget.addDevice(current)) {
                Label(app: "cloud.device.add", systemImage: "qrcode")
            }
            if let sharing {
                ForEach(sharing.invited) { participant in
                    Button {
                        startRenaming(.participant(participant), name: assignedName(participant) ?? "")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: participantTitle(participant))
                            Text(verbatim: participantRow(participant))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            startRenaming(
                                .participant(participant), name: assignedName(participant) ?? "")
                        } label: {
                            Label(app: "cloud.rename", systemImage: "pencil")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await remove(participant) }
                        } label: {
                            Label(app: "cloud.participant.remove", systemImage: "person.badge.minus")
                        }
                    }
                }
                if sharing.invited.isEmpty {
                    Text(app: "cloud.participant.empty").foregroundStyle(ColorTheme.muted.color)
                }
                Button(role: .destructive) {
                    finishQuestion = true
                } label: {
                    Text(app: "cloud.sharing.finish")
                }
            }
        } header: {
            Text(app: "cloud.participant")
        } footer: {
            Text(app: "cloud.participant.text")
        }
    }

    /// The name an owner assigned to a participant.
    private func assignedName(_ t: Participant) -> String? {
        zone.flatMap { CloudHub.participantName(t.identifier, in: $0) }
    }

    /// The devices this participant registered.
    private func deviceNames(_ t: Participant) -> [String] {
        zone.map { CloudHub.devices(from: t.identifier, in: $0).map(\.name) } ?? []
    }

    /// Who that is, in this order: the assigned name, otherwise Apple's name (for a
    /// looked-up Apple ID), otherwise their devices, otherwise "Joined via link".
    private func participantTitle(_ t: Participant) -> String {
        if let name = assignedName(t) { return name }
        if let name = t.name { return name }
        let devices = deviceNames(t)
        return devices.isEmpty ? Phrase.from("cloud.participant.link") : devices.joined(separator: ", ")
    }

    /// "iPad, joined via link, read and write"; the devices only if they are not already
    /// the title.
    private func participantRow(_ t: Participant) -> String {
        var share: [String] = []
        let devices = deviceNames(t)
        if assignedName(t) != nil || t.name != nil, !devices.isEmpty {
            share.append(devices.joined(separator: ", "))
        }
        if t.name == nil { share.append(Phrase.from("cloud.participant.link.small")) }
        share.append(Phrase.from(t.writing ? "cloud.participant.writing" : "cloud.participant.reading"))
        if !t.accepted { share.append(Phrase.from("cloud.participant.invited")) }
        return share.joined(separator: " · ")
    }

    // MARK: - Participant page

    private var participantPage: some View {
        Section {
            LabeledContent {
                Text(verbatim: current.sharedBy ?? "–")
            } label: {
                Text(app: "cloud.sharedBy")
            }
            if zone?.state == .lost {
                Text(app: "cloud.lost").foregroundStyle(ColorTheme.failure.color)
            }
            Button(role: .destructive) {
                leaveQuestion = true
            } label: {
                Text(app: "cloud.leave")
            }
        } footer: {
            Text(app: "cloud.shared.text")
        }
    }

    // MARK: - Actions

    private func load() async {
        if active {
            zone = core.context.cloud
        } else {
            let persistence = profiles.persistence(profile)
            let z = ProfileZone(
                file: persistence.cloud, service: current.cloudSync ? core.cloud.service : nil,
                zone: current.cloud,
                unprompted: false)
            z.sharedBy = current.sharedBy
            zone = z
        }
        await loadSharing()
    }

    private func loadSharing() async {
        guard !current.shared, let identifier = current.cloud, core.cloud.account == .available else {
            return
        }
        do throws(CloudError) {
            sharing = try await core.cloud.sharing(identifier)
        } catch {
            sharing = nil
        }
    }

    private func switchTo(_ to: Bool) async {
        guard to != current.cloudSync else { return }
        running = true
        defer { running = false }
        do throws(CloudError) {
            try await core.switchCloud(to, for: current)
            Haptics.success()
            await load()
        } catch {
            failure = CloudRow.reason(error)
        }
    }

    private func remove(_ participant: Participant) async {
        guard let identifier = current.cloud else { return }
        do throws(CloudError) {
            try await core.cloud.remove(participant: participant.identifier, from: identifier)
            await loadSharing()
        } catch {
            failure = CloudRow.reason(error)
        }
    }

    private func endSharing() async {
        guard let identifier = current.cloud else { return }
        do throws(CloudError) {
            try await core.cloud.endSharing(identifier)
            sharing = nil
            Haptics.success()
        } catch {
            failure = CloudRow.reason(error)
        }
    }

    private func leave() async {
        do throws(CloudError) {
            try await core.removeProfile(current)
            Haptics.success()
        } catch {
            failure = CloudRow.reason(error)
        }
    }

    /// The mirror as JSON in a file under `tmp`, which the share sheet takes.
    private func exportZone(_ zone: ProfileZone) {
        guard let data = zone.export() else { return }
        let file = FileManager.default.temporaryDirectory.appending(
            path: "Akari-\(profile.name)-iCloud.json")
        try? data.write(to: file, options: .atomic)
        export = file
    }
}

/// The sentences for the zone state, for this sheet and the diagnostics row of the statistics.
@MainActor
enum CloudRow {

    static func state(_ zone: ProfileZone) -> String {
        let pendingText = zone.pending > 0 ? " · " + Phrase.from("cloud.state.wait", zone.pending) : ""
        switch zone.state {
        case .withoutCloud: return Phrase.from("cloud.account.local")
        case .noAccount: return Phrase.from("cloud.account.none")
        case .unbound: return Phrase.from("cloud.state.unbound")
        case .neverSynced: return Phrase.from("cloud.state.never") + pendingText
        case .synced(let when):
            return Phrase.from("cloud.state.synced", when.formatted(date: .omitted, time: .shortened))
                + pendingText
        case .unreachable: return Phrase.from("cloud.state.unreachable") + pendingText
        case .lost: return Phrase.from("cloud.lost")
        case .rejected(let reason): return Phrase.from("cloud.state.rejected", reason)
        }
    }

    static func reason(_ failure: CloudError) -> String {
        switch failure {
        case .noAccount: Phrase.from("cloud.account.none")
        case .unreachable: Phrase.from("cloud.state.unreachable")
        case .zoneMissing, .deletedByUser: Phrase.from("cloud.lost")
        case .rejected(let reason), .miscellaneous(let reason): Phrase.from("cloud.state.rejected", reason)
        }
    }
}
