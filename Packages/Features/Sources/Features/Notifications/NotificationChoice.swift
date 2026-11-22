import Foundation
import Observation
import SourcesKit

/// Which podcasts notify when a new episode is out: per profile, in its
/// UserDefaults.
///
/// **Two switches, one above the other.** ``to`` is the main switch in the
/// settings; below it each subscription hangs on one podcast. Off means no polling,
/// no notification; the subscriptions stay, and whoever switches back on finds their
/// selection as it was.
///
/// **Each subscription carries its state**: the date up to which that podcast counts as seen. New is only
/// what arrives after. On subscribing and on switching back on that is "now": whoever
/// switches on after three weeks does not get a flood from three weeks. After a fetch
/// the state moves to the latest arrival the **server** reported, not
/// to the device clock, which can be off against the server's.
@MainActor
@Observable
public final class NotificationChoice {

    // Storage keys (UserDefaults): they stay German although catalog keys of the same text exist.
    static let onKey = "mitteilungen.an"
    static let subscriptionsKey = "mitteilungen.podcasts"

    /// The main switch.
    public private(set) var to: Bool
    /// Podcast to the date it is seen up to.
    public private(set) var subscriptions: [SeriesID: Date]

    private let persistence: UserDefaults

    public init(persistence: UserDefaults) {
        self.persistence = persistence
        to = persistence.bool(forKey: Self.onKey)
        subscriptions =
            persistence.data(forKey: Self.subscriptionsKey)
            .flatMap { try? JSONDecoder().decode([StoredSubscription].self, from: $0) }
            .map { Dictionary($0.map { ($0.podcast, $0.seen) }, uniquingKeysWith: max) } ?? [:]
    }

    public func subscribed(_ podcast: SeriesID) -> Bool { subscriptions[podcast] != nil }

    /// Flip the main switch. When switching on, every subscription counts as seen from now.
    public func switchTo(_ new: Bool, now: Date = Date()) {
        if new, !to { subscriptions = subscriptions.mapValues { _ in now } }
        to = new
        secure()
    }

    /// Subscribe or unsubscribe a podcast; a new subscription counts from now.
    public func subscribe(_ podcast: SeriesID, _ new: Bool, now: Date = Date()) {
        if new {
            if subscriptions[podcast] == nil { subscriptions[podcast] = now }
        } else {
            subscriptions[podcast] = nil
        }
        secure()
    }

    /// After a fetch: a podcast's state moves to its latest arrival.
    func advance(_ seen: [SeriesID: Date]) {
        var changed = false
        for (podcast, until) in seen {
            guard let old = subscriptions[podcast], until > old else { continue }
            subscriptions[podcast] = until
            changed = true
        }
        if changed { secure() }
    }

    private func secure() {
        persistence.set(to, forKey: Self.onKey)
        let list = subscriptions.map { StoredSubscription(podcast: $0.key, seen: $0.value) }
        persistence.set(try? JSONEncoder().encode(list), forKey: Self.subscriptionsKey)
    }

    private struct StoredSubscription: Codable {
        let podcast: SeriesID
        let seen: Date

        // Stored key names stay as written by earlier versions.
        private enum CodingKeys: String, CodingKey {
            case podcast
            case seen = "gesehen"
        }
    }
}
