import CoreGraphics
import Foundation
import SourcesKit

/// What the player needs to know about an audiobook - and what it calls back.
///
/// Like ``Reader`` and ``ReaderBook`` without library and server: the tracks with
/// header lines and transport (the bridge fetches them), the chapters, the spot to
/// continue from, and a callback for the state. The cover comes as a function -
/// for the sheet and the lock screen.
public struct Audiobook: Identifiable, Sendable {

    public let id: String
    public let name: String
    /// Author - the second line; on the lock screen the "artist".
    public let subline: String?
    public let narrator: String?
    public let volume: AudioManifest
    public let headerLines: [String: String]
    public let transport: any Transport
    /// Where to continue, in seconds.
    public let start: TimeInterval
    public let image: @Sendable () async -> CGImage?
    /// A state is reached - `completed` at the end.
    public let report: @MainActor @Sendable (_ second: TimeInterval, _ completed: Bool) -> Void
    /// "To the series" - `nil` without a series.
    public let toSeries: (@MainActor @Sendable () -> Void)?

    public init(
        id: String, name: String, subline: String? = nil, narrator: String? = nil, volume: AudioManifest,
        headerLines: [String: String] = [:], transport: any Transport = URLSession.shared,
        start: TimeInterval = 0,
        image: @escaping @Sendable () async -> CGImage? = { nil },
        report: @escaping @MainActor @Sendable (TimeInterval, Bool) -> Void = { _, _ in },
        toSeries: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.name = name
        self.subline = subline
        self.narrator = narrator
        self.volume = volume
        self.headerLines = headerLines
        self.transport = transport
        self.start = min(max(start, 0), max(volume.duration, 0))
        self.image = image
        self.report = report
        self.toSeries = toSeries
    }
}
