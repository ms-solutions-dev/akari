import Foundation
import SourcesKit

/// What the book reader needs to know about a book - and what it calls back.
///
/// Like the ``Reader`` of the comic reader it knows neither library nor server:
/// a file on the device (EPUB or PDF, Readium detects the format), the
/// spot to continue from, and callbacks for the state. Whoever opens the reader
/// (`Features`) fetched the file beforehand and knows where a state goes.
public struct ReaderBook: Identifiable, Sendable {

    public let id: String
    /// The book title - the first line in the HUD.
    public let name: String
    /// "Sandmeer - Volume 6" - the second line; without a series the author, otherwise `nil`.
    public let subline: String?
    public let file: URL
    /// Where to continue - `nil` from the start. A CFI for EPUB, a page for PDF,
    /// a fraction if nothing more precise is available.
    public let start: ReadingState.Position?
    /// The book is kept on the device - then "Keep" is missing from the menu.
    public let keep: Bool
    /// A spot was reached - `completed` if it was the last page.
    public let report: @MainActor @Sendable (_ spot: ReadingState.Position, _ completed: Bool) -> Void
    /// "Keep book" from the menu.
    public let requestKeep: @MainActor @Sendable () -> Void
    /// What comes after the end: the next volume, otherwise a saved book.
    public let continuation: Continuation?
    /// "To the series" in the menu and at the end; `nil` without a series.
    public let toSeries: (@MainActor @Sendable () -> Void)?

    /// The suggestion on the end-of-book sheet.
    public struct Continuation: Sendable {
        public enum Kind: Sendable {
            case nextVolume, saved
        }
        public let kind: Kind
        public let name: String
        public let subline: String?
        public let open: @MainActor @Sendable () -> Void

        public init(
            kind: Kind, name: String, subline: String?, open: @escaping @MainActor @Sendable () -> Void
        ) {
            self.kind = kind
            self.name = name
            self.subline = subline
            self.open = open
        }
    }

    public init(
        id: String, name: String, subline: String? = nil, file: URL, start: ReadingState.Position? = nil,
        keep: Bool = false,
        report: @escaping @MainActor @Sendable (ReadingState.Position, Bool) -> Void = { _, _ in },
        requestKeep: @escaping @MainActor @Sendable () -> Void = {}, continuation: Continuation? = nil,
        toSeries: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.name = name
        self.subline = subline
        self.file = file
        self.start = start
        self.keep = keep
        self.report = report
        self.requestKeep = requestKeep
        self.continuation = continuation
        self.toSeries = toSeries
    }
}
