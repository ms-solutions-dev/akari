import Foundation

/// A podcast episode that is new on the server — what the episode watch needs to write a
/// notification, and no more: not a whole ``Title``, because the list of the latest
/// episodes in the background should manage without the podcast's detail.
public struct NewAddition: Sendable, Hashable {
    /// The episode as a title — the same identifier as in the library (`item:episode` for Audiobookshelf).
    public let identifier: TitleID
    /// The podcast as a series — what the subscription hangs on.
    public let podcast: SeriesID
    public let podcastName: String
    public let name: String
    /// When the server received the episode — not when it was published: an episode
    /// that arrives today is new today, even if the feed dates it yesterday.
    public let arrived: Date

    public init(
        identifier: TitleID, podcast: SeriesID, podcastName: String, name: String, arrived: Date
    ) {
        self.identifier = identifier
        self.podcast = podcast
        self.podcastName = podcastName
        self.name = name
        self.arrived = arrived
    }
}
