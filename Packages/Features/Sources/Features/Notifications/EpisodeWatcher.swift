import Bedrock
import Foundation
import SourcesKit
import UserNotifications

/// A finished notification about new episodes of a podcast, which the `SystemSender` hands
/// to the system. One per podcast and fetch: three new episodes make one notification,
/// "3 new episodes", not three.
public struct EpisodeNotice: Sendable, Equatable {
    /// The identifier at the system: the newest episode. If the same episode arrives twice,
    /// the second notification replaces the first instead of sitting beside it.
    public let identifier: String
    /// The podcast as thread; the system stacks its notifications.
    public let thread: String
    public let title: String
    public let text: String
    /// One episode: the episode. Several: the podcast.
    public let link: URL
}

/// Checks for new episodes of subscribed podcasts and turns them into notifications.
///
/// The path is deliberately narrow: one fetch of the latest episodes per source
/// (`Source.latestEpisodes()`), no extract, no shelf. In the background the app has roughly
/// 30 seconds and the shelf is not needed there. A source that does not answer drops out
/// silently: on the go without VPN the home server is not there, and that is no reason
/// for a notification; its state stays and the next run catches up.
enum EpisodeWatcher {

    /// What arrived since the respective subscription's state; subscribed podcasts only.
    static func new(_ episodes: [NewAddition], subscriptions: [SeriesID: Date]) -> [NewAddition] {
        episodes.filter { f in subscriptions[f.podcast].map { f.arrived > $0 } ?? false }
    }

    /// Per podcast the latest arrival: the new state of the subscriptions.
    static func seen(_ episodes: [NewAddition]) -> [SeriesID: Date] {
        Dictionary(episodes.map { ($0.podcast, $0.arrived) }, uniquingKeysWith: max)
    }

    /// One notification per podcast, newest episode first.
    static func messages(_ new: [NewAddition]) -> [EpisodeNotice] {
        let perPodcast = Dictionary(grouping: Set(new), by: \.podcast)
        return perPodcast.values
            .map { $0.sorted { $0.arrived > $1.arrived } }
            .sorted { $0[0].arrived > $1[0].arrived }
            .map { episodes in
                let youngest = episodes[0]
                return EpisodeNotice(
                    identifier: "folge-\(youngest.identifier)",
                    thread: "podcast-\(youngest.podcast)",
                    title: youngest.podcastName,
                    text: episodes.count == 1
                        ? youngest.name
                        : Phrase.from("notification.episodes", episodes.count) + " · " + youngest.name,
                    link: episodes.count == 1
                        ? Deeplink.title(youngest.identifier).url : Deeplink.series(youngest.podcast).url)
            }
    }

    /// One pass: asks the sources, advances the states, returns the notifications.
    /// Without the master switch or without a subscription it asks nobody.
    @MainActor
    static func check(
        source: (SourceID) -> (any Source)?, choice: NotificationChoice
    ) async -> [EpisodeNotice] {
        guard choice.to, !choice.subscriptions.isEmpty else { return [] }
        let asked = Set(choice.subscriptions.keys.map(\.source)).compactMap(source)
        let start = Date()
        var episodes: [NewAddition] = []
        for source in asked {
            do {
                episodes += try await source.latestEpisodes()
            } catch {
                Diagnostics.step(
                    "Episode watcher: \(source.identifier) not asked: \(error)", since: nil,
                    area: "Notifications")
            }
        }
        let new = new(episodes, subscriptions: choice.subscriptions)
        choice.advance(seen(episodes))
        Diagnostics.step(
            "Episode watch: \(episodes.count) episodes seen, \(new.count) new", since: start,
            area: "Notifications")
        return messages(new)
    }
}

/// Whoever delivers notifications and asks for permission: the system in operation, a
/// mailbox in a test.
@MainActor
public protocol NotificationSender: AnyObject {
    /// Asks the system the first time; afterwards the answer from back then.
    func allow() async -> Bool
    /// Whether notifications may be delivered, without asking.
    func allowed() async -> Bool
    func spot(_ messages: [EpisodeNotice]) async
}

/// The sender in operation: `UNUserNotificationCenter`.
@MainActor
public final class SystemSender: NotificationSender {

    public init() {}

    public func allow() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]))
            ?? false
    }

    public func allowed() async -> Bool {
        let state = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return state == .authorized || state == .provisional
    }

    public func spot(_ messages: [EpisodeNotice]) async {
        let hub = UNUserNotificationCenter.current()
        for message in messages {
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.text
            content.sound = .default
            content.threadIdentifier = message.thread
            content.userInfo = [SystemSender.linkKey: message.link.absoluteString]
            do {
                try await hub.add(
                    UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil))
            } catch {
                Diagnostics.deficiency(
                    "Notification not delivered: \(error.localizedDescription)", since: nil,
                    area: "Notifications")
            }
        }
    }

    /// Under this key a notification carries its link; the app delegate reads it on tap.
    public nonisolated static let linkKey = "link"
}
