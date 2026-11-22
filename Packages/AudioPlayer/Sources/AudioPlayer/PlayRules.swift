import Foundation
import SourcesKit

/// The player's rules as pure functions - testable without sound.
public enum PlayRules {

    /// How far to rewind after a pause so the thread is back
    /// - the curve: 0 / 3 / 10 / 20 / 30 seconds.
    public static func rewind(afterPause duration: TimeInterval) -> TimeInterval {
        switch duration {
        case ..<5: 0
        case ..<60: 3
        case ..<(10 * 60): 10
        case ..<(60 * 60): 20
        default: 30
        }
    }

    /// Where the player gets a track: a file on the device directly,
    /// one from the server via the bridge - and without a bridge not at all (then it is missing
    /// instead of AVPlayer failing on the audiobook host).
    ///
    /// - Parameter bridge: `address(track:)` of the running ``AudioBridge``, `nil` without.
    public static func address(track index: Int, in volume: AudioManifest, bridge: ((Int) -> URL)?) -> URL? {
        guard volume.tracks.indices.contains(index) else { return nil }
        let track = volume.tracks[index]
        if track.address.isFileURL { return track.address }
        return bridge?(index)
    }

    /// The track in which `time` lies - the last one if the time lies beyond.
    public static func track(for time: TimeInterval, in volume: AudioManifest) -> Int? {
        guard !volume.tracks.isEmpty else { return nil }
        if let i = volume.tracks.firstIndex(where: { time < $0.end && time >= $0.startTime }) { return i }
        return time < 0 ? 0 : volume.tracks.count - 1
    }

    /// The chapter in which `time` lies.
    public static func chapter(for time: TimeInterval, in volume: AudioManifest) -> Int? {
        guard !volume.chapter.isEmpty else { return nil }
        if let i = volume.chapter.firstIndex(where: { time >= $0.startTime && time < $0.end }) { return i }
        return time >= (volume.chapter.last?.end ?? 0) ? volume.chapter.count - 1 : 0
    }

    /// "Back" with chapter threshold: in the first seconds of a chapter
    /// it goes to the previous chapter, otherwise to the start of the current one.
    public static let chapterThreshold: TimeInterval = 3

    public static func previousChapter(from time: TimeInterval, in volume: AudioManifest) -> TimeInterval {
        guard let i = chapter(for: time, in: volume) else { return 0 }
        let current = volume.chapter[i]
        if time - current.startTime < chapterThreshold, i > 0 { return volume.chapter[i - 1].startTime }
        return current.startTime
    }

    public static func nextChapter(from time: TimeInterval, in volume: AudioManifest) -> TimeInterval? {
        guard let i = chapter(for: time, in: volume), i + 1 < volume.chapter.count else { return nil }
        return volume.chapter[i + 1].startTime
    }

    /// From when an audiobook counts as finished - the last five seconds are outro.
    public static func finished(_ time: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && time >= duration - 5
    }

    /// The speeds of the control.
    public static let tempos: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// How often the state is reported while playing (15-20 s).
    public static let reportInterval: TimeInterval = 15

    /// Time as "1:23:45" or "23:45".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0).rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
}

/// The sleep timer: minutes or the end of the chapter.
public enum SleepTimer: Hashable, Sendable, Codable {
    case minutes(Int)
    case chapterEnd

    public static let selection: [SleepTimer] = [
        .minutes(5), .minutes(10), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .chapterEnd,
    ]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case minutes = "minuten"
        case chapterEnd = "kapitelende"
    }
    enum MinutesCodingKeys: String, CodingKey, CaseIterable {
        case _0
    }
}

/// What the player remembers: skip distances, speed, the last choice for the
/// sleep timer - in UserDefaults under `spieler.*`.
@MainActor
@Observable
public final class PlayDefaults {

    public var jumpForward: Int {
        didSet { persistence.set(jumpForward, forKey: PlayDefaults.prefix + "sprungVor") }
    }
    public var jumpBack: Int {
        didSet { persistence.set(jumpBack, forKey: PlayDefaults.prefix + "sprungZurueck") }
    }
    public var tempo: Double { didSet { persistence.set(tempo, forKey: PlayDefaults.prefix + "tempo") } }
    public var sleep: SleepTimer? {
        didSet {
            persistence.set(
                sleep.flatMap { try? JSONEncoder().encode($0) }, forKey: PlayDefaults.prefix + "schlaf")
        }
    }

    public static let jumpDistances = [10, 15, 30, 45, 60]
    private let persistence: UserDefaults
    private static let prefix = "spieler."

    public init(persistence: UserDefaults = .standard) {
        self.persistence = persistence
        jumpForward = persistence.object(forKey: PlayDefaults.prefix + "sprungVor") as? Int ?? 30
        jumpBack = persistence.object(forKey: PlayDefaults.prefix + "sprungZurueck") as? Int ?? 15
        tempo = persistence.object(forKey: PlayDefaults.prefix + "tempo") as? Double ?? 1.0
        sleep = (persistence.data(forKey: PlayDefaults.prefix + "schlaf")).flatMap {
            try? JSONDecoder().decode(SleepTimer.self, from: $0)
        }
    }
}
