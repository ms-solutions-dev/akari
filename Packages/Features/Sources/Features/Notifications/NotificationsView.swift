import DesignSystem
import Library
import SourcesKit
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Settings, Notifications: the master switch and below it each podcast with its own
/// switch.
///
/// **The master switch asks the system**, not app launch. If the reader declines there, the
/// switch stays on and the page says where it can be allowed: a switch that resets itself
/// looks like a bug.
///
/// **The sentence about timing is there on purpose.** iOS decides when the app may check in
/// the background: sometimes after minutes, sometimes after hours, barely at all for rarely
/// used apps. And a home server without VPN is not reachable on the go. Whoever knows this
/// does not take the app for broken.
struct NotificationsView: View {

    @Environment(NotificationChoice.self) private var choice
    @Environment(LibraryService.self) private var inventory
    @Environment(AppCore.self) private var core
    @Environment(\.openURL) private var open
    @State private var allowed: Bool?

    var body: some View {
        let podcasts = inventory.shelf.allSeries.filter { $0.kind == .podcast }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        List {
            Section {
                Toggle(isOn: Binding(get: { choice.to }, set: switchTo)) {
                    Text(app: "notifications.switch")
                }
            } footer: {
                Text(app: "notifications.switch.hint")
            }

            if choice.to, allowed == false {
                Section {
                    Text(app: "notifications.forbidden")
                        .font(.subheadline)
                    #if os(iOS)
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                open(url)
                            }
                        } label: {
                            Label(app: "notifications.systemSettings", systemImage: "gear")
                        }
                    #endif
                }
            }

            if choice.to {
                Section {
                    if podcasts.isEmpty {
                        Text(app: "notifications.noPodcasts")
                            .font(.subheadline)
                            .foregroundStyle(ColorTheme.muted.color)
                    }
                    ForEach(podcasts) { podcast in
                        Toggle(
                            isOn: Binding(
                                get: { choice.subscribed(podcast.identifier) },
                                set: { choice.subscribe(podcast.identifier, $0) })
                        ) {
                            Text(verbatim: podcast.name)
                        }
                    }
                } header: {
                    Text(app: "notifications.podcasts")
                } footer: {
                    Text(app: "notifications.moment")
                }
            }
        }
        .paper()
        .navigationTitle(Text(app: "notifications.title"))
        .task { allowed = await core.sender.allowed() }
    }

    private func switchTo(_ new: Bool) {
        choice.switchTo(new)
        guard new else { return }
        Task { allowed = await core.sender.allow() }
    }
}

/// "Notify about new episodes" in a podcast's menu: subscribes to it and, if necessary,
/// switches the master switch on too. Whoever rings the bell wants to be notified, and a
/// detour through settings would be a trap.
struct EpisodeBell: View {

    let podcast: SeriesID

    @Environment(NotificationChoice.self) private var choice
    @Environment(AppCore.self) private var core

    var body: some View {
        let to = choice.to && choice.subscribed(podcast)
        Button {
            if to {
                choice.subscribe(podcast, false)
            } else {
                choice.subscribe(podcast, true)
                if !choice.to { choice.switchTo(true) }
                Task { _ = await core.sender.allow() }
            }
        } label: {
            if to {
                Label(app: "notifications.bell.off", systemImage: "bell.slash")
            } else {
                Label(app: "notifications.bell.on", systemImage: "bell")
            }
        }
    }
}
