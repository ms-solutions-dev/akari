import Foundation
import SourcesKit

/// What the reader needs to know about a volume - and what it calls back.
///
/// The reader knows neither library nor store nor server: it is given addresses,
/// header lines and a transport (or files, when the volume is kept) and
/// reports pages back. Whoever opens it (`Features`) builds this from title,
/// source and shelf - and knows the next volume.
public struct Reader: Identifiable, Sendable {

    public let id: String
    /// The name of the series, otherwise of the title - the first line in the HUD.
    public let name: String
    /// "Volume 47" - the second line; `nil` without a series.
    public let subline: String?
    public let count: Int
    public let address: @Sendable (Int) -> URL
    public let measures: (@Sendable () async throws -> [PageSize])?
    /// The pages on the device - a kept volume; then nothing goes over the network.
    public let files: [URL]?
    public let headerLines: [String: String]
    public let transport: any Transport
    /// The series key for the per-series presets; `nil` without a series.
    public let series: String?
    /// What the server carries as reading direction.
    public let serverDirection: ReadingDirection?
    /// Where to continue - 1 if never started; the last page when finished
    /// (then the volume-end spread is one tap away).
    public let startPage: Int
    /// The volume is entirely on the device - then there is no "Keep volume" toast.
    public let keep: Bool
    /// A page was reached - `completed` if it was the last.
    public let report: @MainActor @Sendable (_ page: Int, _ completed: Bool) -> Void
    /// "Keep volume" from the toast or the menu.
    public let requestKeep: @MainActor @Sendable () -> Void

    public init(
        id: String, name: String, subline: String?, count: Int, address: @escaping @Sendable (Int) -> URL,
        measures: (@Sendable () async throws -> [PageSize])? = nil, files: [URL]? = nil,
        headerLines: [String: String] = [:], transport: any Transport = URLSession.shared,
        series: String? = nil,
        serverDirection: ReadingDirection? = nil, startPage: Int = 1, keep: Bool = false,
        report: @escaping @MainActor @Sendable (Int, Bool) -> Void = { _, _ in },
        requestKeep: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.id = id
        self.name = name
        self.subline = subline
        self.count = max(count, 1)
        self.address = address
        self.measures = measures
        self.files = files
        self.headerLines = headerLines
        self.transport = transport
        self.series = series
        self.serverDirection = serverDirection
        self.startPage = min(max(startPage, 1), max(count, 1))
        self.keep = keep
        self.report = report
        self.requestKeep = requestKeep
    }

    /// From a ``ContentSource`` - only a page stream qualifies; everything else is
    /// not a comic and gives `nil`.
    public static func from(
        _ content: ContentSource, id: String, name: String, subline: String?, files: [URL]? = nil,
        headerLines: [String: String], transport: any Transport, series: String?,
        serverDirection: ReadingDirection?, startPage: Int, keep: Bool,
        report: @escaping @MainActor @Sendable (Int, Bool) -> Void,
        requestKeep: @escaping @MainActor @Sendable () -> Void
    ) -> Reader? {
        guard case .pageStream(let count, let page, let measures) = content else { return nil }
        return Reader(
            id: id, name: name, subline: subline, count: count, address: page, measures: measures,
            files: files, headerLines: headerLines, transport: transport, series: series,
            serverDirection: serverDirection, startPage: startPage, keep: keep, report: report,
            requestKeep: requestKeep)
    }
}
