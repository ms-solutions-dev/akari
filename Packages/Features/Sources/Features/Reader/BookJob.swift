import Foundation
import SourcesKit
import SwiftUI

/// The job handed to the book reader. It mirrors the reader package's own type but is
/// defined here so that `Features` does not need to know that package: Readium does not
/// support macOS, and `swift test` should keep running on the Mac.
/// The app target puts the reader into the environment via ``ReaderFactory`` and
/// translates field by field.
public struct BookJob: Identifiable, Sendable {

    public let id: String
    public let name: String
    public let subline: String?
    /// The file on the device: kept, or just fetched into the cache.
    public let file: URL
    public let start: ReadingState.Position?
    public let keep: Bool
    public let report: @MainActor @Sendable (_ spot: ReadingState.Position, _ completed: Bool) -> Void
    public let requestKeep: @MainActor @Sendable () -> Void
    public let continuation: Continuation?
    public let toSeries: (@MainActor @Sendable () -> Void)?

    /// What the end-of-book sheet suggests: the next volume, otherwise a saved book.
    public struct Continuation: Sendable {
        public enum Kind: Sendable {
            case nextVolume, saved
        }
        public let kind: Kind
        public let name: String
        public let subline: String?
        public let open: @MainActor @Sendable () -> Void
    }
}

/// The slot: whoever turns a `BookJob` into a view. `nil` means no reader is plugged
/// in, and the shell then shows the notice sheet (on the Mac, in previews).
public typealias ReaderFactory = @MainActor (BookJob) -> AnyView

private struct ReaderFactoryKey: EnvironmentKey {
    static let defaultValue: ReaderFactory? = nil
}

/// "In book" outside the reader (title detail): identifier and file in, view out, or
/// `nil` while the book has never been opened. Plugged in by the app like ``ReaderFactory``.
public typealias InBookFactory = @MainActor (_ id: String, _ file: URL) -> AnyView?

private struct InBookFactoryKey: EnvironmentKey {
    static let defaultValue: InBookFactory? = nil
}

extension EnvironmentValues {
    public var inBook: InBookFactory? {
        get { self[InBookFactoryKey.self] }
        set { self[InBookFactoryKey.self] = newValue }
    }

    public var bookReader: ReaderFactory? {
        get { self[ReaderFactoryKey.self] }
        set { self[ReaderFactoryKey.self] = newValue }
    }
}
