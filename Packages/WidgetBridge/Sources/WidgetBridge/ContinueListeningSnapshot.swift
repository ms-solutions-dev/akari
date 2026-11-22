import Foundation

/// The "Continue listening" snapshot: the audiobook last listened to by the **active**
/// profile — the one in the player, otherwise the most recent from the continue-listening row — and whether it
/// is currently playing.
///
/// **Why it carries the position as a number and not as a word:** the widget computes the
/// remaining time itself, for every entry of its timeline — if the audiobook is playing,
/// it creates one entry per minute and counts on from ``written`` at the playback pace
/// (``time(asOf:)``). That keeps the remaining time usable without the app writing every
/// minute and the extension reloading. (Reloading costs no budget
/// as long as the app has an audio session or is in the foreground — but a file every minute
/// and a new widget process for a number that can be predicted would be
/// a waste.) The app writes on start, pause, jump and chapter change — and
/// every five minutes, so that a jump by the system (track ended, sleep timer) does not
/// go unnoticed forever.
public struct ContinueListeningSnapshot: Codable, Sendable, Equatable {

    public struct Audiobook: Codable, Sendable, Equatable {
        /// The title id as text — for the intent, so the app knows whether that is the same book
        /// in the player.
        public let id: String
        public let name: String
        /// The author — or the narrator if there is no author.
        public let subline: String?
        /// The current chapter — `nil` if the volume has no chapters or the
        /// snapshot comes from the shelf (which only has the state).
        public let chapter: String?
        /// The position in the book in seconds, as it was when written.
        public let time: TimeInterval
        public let duration: TimeInterval
        /// The pace at which the position keeps moving — 1 if it is not playing.
        public let tempo: Double
        public let running: Bool
        /// `akari://lesen/…` — the tap leads into the player.
        public let link: URL
        /// The file name of the cover in the folder, `nil` without a cover.
        public let cover: String?

        public init(
            id: String, name: String, subline: String?, chapter: String?, time: TimeInterval,
            duration: TimeInterval, tempo: Double = 1, running: Bool, link: URL, cover: String?
        ) {
            self.id = id
            self.name = name
            self.subline = subline
            self.chapter = chapter
            self.time = min(max(time, 0), max(duration, 0))
            self.duration = max(duration, 0)
            self.tempo = tempo > 0 ? tempo : 1
            self.running = running
            self.link = link
            self.cover = cover
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case id
            case name
            case subline = "unterzeile"
            case chapter = "kapitel"
            case time = "zeit"
            case duration = "dauer"
            case tempo
            case running = "laeuft"
            case link
            case cover
        }
    }

    public let profile: String
    public let multipleProfiles: Bool
    /// `nil` means: this profile has not started an audiobook.
    public let audiobook: Audiobook?
    public let written: Date

    public init(
        profile: String, multipleProfiles: Bool = false, audiobook: Audiobook?, written: Date = Date()
    ) {
        self.profile = profile
        self.multipleProfiles = multipleProfiles
        self.audiobook = audiobook
        self.written = written
    }

    public static func empty(profile: String, multipleProfiles: Bool = false) -> ContinueListeningSnapshot {
        ContinueListeningSnapshot(profile: profile, multipleProfiles: multipleProfiles, audiobook: nil)
    }

    /// The position at a point in time: if playing, it has moved on since ``written`` at the
    /// pace — at most to the end; if stopped, it is as it was.
    public func time(asOf now: Date) -> TimeInterval {
        guard let audiobook else { return 0 }
        guard audiobook.running else { return audiobook.time }
        let elapsed = max(now.timeIntervalSince(written), 0)
        return min(audiobook.time + elapsed * audiobook.tempo, audiobook.duration)
    }

    /// What is left of the book, in seconds of playing time.
    public func remainder(asOf now: Date) -> TimeInterval {
        guard let audiobook else { return 0 }
        return max(audiobook.duration - time(asOf: now), 0)
    }

    /// 0 … 1 for the bar.
    public func fraction(asOf now: Date) -> Double {
        guard let audiobook, audiobook.duration > 0 else { return 0 }
        return min(max(time(asOf: now) / audiobook.duration, 0), 1)
    }

    /// When the book would end at the current pace — `nil` if it is stopped. The
    /// widget creates one entry per minute until then (at most one hour).
    public func end(from now: Date) -> Date? {
        guard let audiobook, audiobook.running else { return nil }
        return now.addingTimeInterval(remainder(asOf: now) / audiobook.tempo)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case profile = "profil"
        case multipleProfiles = "mehrereProfile"
        case audiobook = "hoerbuch"
        case written = "geschrieben"
    }
}
