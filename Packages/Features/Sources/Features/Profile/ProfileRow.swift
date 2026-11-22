import AccountsKit
import CloudSync
import DesignSystem
import SwiftUI

/// "Who is reading?": the top section of the account sheet. The circles of all profiles
/// side by side, the active one marked, "New profile" after them, and "Manage" below. A
/// tap on another circle switches immediately, for a protected profile via the
/// ``PinSheet``.
///
/// No sheet of its own: the account sheet is rarely needed, and whoever opens it wants
/// either to switch or to see which server is failing. Both fit on one sheet, with the
/// switch on top because it is the more frequent action.
///
/// A child profile sees the circles (and switches to a parent only with their PIN), but
/// neither "New profile" nor "Manage".
struct ProfileRow: View {

    @Environment(ProfileRegistry.self) private var profiles
    @Environment(\.profile) private var profile
    @Environment(\.theme) private var theme
    @State private var pinFor: Profile?

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(profiles.all) { entry in
                        Button {
                            choose(entry)
                        } label: {
                            circle(entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: entry.name))
                        .accessibilityHint(
                            entry.id == profile.id ? Text(app: "profile.active") : Text(app: "profile.switch")
                        )
                        .accessibilityAddTraits(entry.id == profile.id ? [.isSelected] : [])
                    }
                    if !profile.kind {
                        NavigationLink(value: AccountTarget.createProfile) {
                            VStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(Typography.title(.title2, weight: .regular))
                                    .foregroundStyle(theme.accent.color)
                                    .frame(width: 56, height: 56)
                                    .overlay {
                                        Circle().strokeBorder(
                                            theme.hairline.color,
                                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                    }
                                Text(app: "profile.new")
                                    .font(.caption)
                                    .foregroundStyle(ColorTheme.muted.color)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .frame(width: 80)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            // On the row content, not the section: a section with a modifier is a
            // row to the list, no longer a section.
            .sheet(item: $pinFor) { target in
                PinSheet(profile: target) { (pin: String) throws(ProfileError) in
                    try profiles.switchTo(to: target, pin: pin)
                }
            }
            // `AKARI_PROBE=pin`: the PIN sheet for the first protected, inactive
            // profile, for the screenshot.
            .onAppear {
                if ProcessInfo.processInfo.environment["AKARI_PROBE"] == "pin", pinFor == nil {
                    pinFor = profiles.all.first { $0.protected && $0.id != profile.id }
                }
            }
            if !profile.kind {
                NavigationLink(value: AccountTarget.manageProfile) {
                    Label(app: "profile.manage", systemImage: "person.2")
                }
            }
        } header: {
            Text(app: "profile.whoReads")
        }
    }

    /// A circle with the name below: the active profile with a ring, a protected one with
    /// a lock, a child profile with the age, an accepted (shared) one with two heads.
    private func circle(_ entry: Profile) -> some View {
        VStack(spacing: 6) {
            ProfileImage(profile: entry, size: 56)
                .overlay {
                    if entry.id == profile.id {
                        Circle().strokeBorder(theme.accent.color, lineWidth: 2.5).padding(-4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if entry.protected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ColorTheme.typography.color)
                            .frame(width: 20, height: 20)
                            .background(theme.paper.color, in: Circle())
                            .overlay { Circle().strokeBorder(theme.hairline.color, lineWidth: 1) }
                            .offset(x: 4, y: 4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if entry.shared {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ColorTheme.typography.color)
                            .frame(width: 20, height: 20)
                            .background(theme.paper.color, in: Circle())
                            .overlay { Circle().strokeBorder(theme.hairline.color, lineWidth: 1) }
                            .offset(x: -4, y: 4)
                            .accessibilityLabel(Text(app: "profile.shared"))
                    }
                }
            Text(verbatim: entry.name)
                .font(.caption)
                .fontWeight(entry.id == profile.id ? .semibold : .regular)
                // Two lines instead of a truncated "New pro..."
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
            if let age = entry.maxAge {
                Text(verbatim: Phrase.from("profile.age.short", age))
                    .font(.caption2)
                    .foregroundStyle(ColorTheme.muted.color)
            }
        }
        .frame(width: 72)
    }

    private func choose(_ target: Profile) {
        guard target.id != profile.id else { return }
        if target.protected {
            pinFor = target
        } else {
            Haptics.selection()
            try? profiles.switchTo(to: target)
        }
    }
}

/// "Manage": the profiles as a list, each row leads into the form.
struct ProfileManagement: View {

    @Environment(ProfileRegistry.self) private var profiles
    @Environment(AppCore.self) private var core
    /// The profile that is about to be removed by swipe. The confirmation hangs on the
    /// list, not the row (a dialog on a swipe button disappears with the row).
    @State private var toRemove: Profile?
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                ForEach(profiles.all) { entry in
                    NavigationLink(value: AccountTarget.editProfile(entry)) {
                        HStack(spacing: 12) {
                            ProfileImage(profile: entry, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: entry.name)
                                Text(verbatim: subline(entry))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    // Swipe left to remove, as in every iOS list; the button at the bottom
                    // of the form went unnoticed. The last profile stays.
                    .swipeActions(edge: .trailing) {
                        if profiles.all.count > 1 {
                            Button(role: .destructive) {
                                toRemove = entry
                            } label: {
                                Label(app: "profile.remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                Text(app: "profile.manage.text")
            }
        }
        .paper()
        .navigationTitle(Text(app: "profile.manage"))
        .toolbarTitleDisplayMode(.inline)
        .confirmationDialog(
            Text(app: "profile.remove.question"),
            isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                guard let profile = toRemove else { return }
                toRemove = nil
                Task {
                    do throws(CloudError) {
                        try await core.removeProfile(profile)
                        Haptics.success()
                    } catch {
                        failure = CloudRow.reason(error)
                    }
                }
            } label: {
                Text(app: "profile.remove")
            }
        } message: {
            Text(app: "profile.remove.text.short")
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

    /// "Child up to 12, PIN" / "PIN" / "Adult" / "shared by ..." - what the row says
    /// about the profile.
    private func subline(_ entry: Profile) -> String {
        var share: [String] = []
        if let age = entry.maxAge { share.append(Phrase.from("profile.age.level", age)) }
        if entry.protected { share.append(Phrase.from("profile.pin.short")) }
        if entry.shared {
            share.append(
                entry.sharedBy.map { Phrase.from("profile.sharedBy", $0) } ?? Phrase.from("profile.shared"))
        }
        if entry.id == profiles.active.id { share.append(Phrase.from("profile.active")) }
        return share.isEmpty ? Phrase.from("profile.adult") : share.joined(separator: " · ")
    }
}
