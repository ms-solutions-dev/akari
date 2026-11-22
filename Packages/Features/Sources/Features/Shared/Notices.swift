import Observation
import OfflineStore
import SourcesKit
import SwiftUI

extension SourceError {
    /// Interprets what went wrong when fetching a file or an audio stream, including the
    /// status rejection of the file fetcher, which is not a ``SourceError``. What the
    /// reader then shows is a sentence from the catalog (``lookupKey``), never the
    /// description of a `URLError` (which used to put "Error Domain=NSURLErrorDomain
    /// Code=-1009" under the cover).
    static func onFetch(_ error: Error, source: SourceID, title: TitleID? = nil) -> SourceError {
        if case FileFetcher.Failure.status(let status) = error {
            return from(status: status, source: source, title: title)
                ?? .unreadable(source, "Response \(status)")
        }
        return from(error, source: source)
    }
}

/// The mailbox for rejections from the background: a write to the server that fails
/// lands here, and the shell shows it as a message. The tile has already rolled back
/// its state; the message only says why.
@MainActor
@Observable
final class Notices {
    var failure: SourceError?

    /// Runs a server action and reports what goes wrong, so the caller needs no
    /// `do/catch`.
    func tryRun(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch let failure as SourceError {
                self.failure = failure
            } catch {
                self.failure = .unreadable(
                    SourceID(provider: .komga, server: ""), String(describing: Swift.type(of: error)))
            }
        }
    }
}

extension View {
    /// The message for a failed write, shown once in the shell.
    func noticeMessage(_ notices: Notices) -> some View {
        alert(
            Text(app: "hint.notSaved"),
            isPresented: Binding(get: { notices.failure != nil }, set: { if !$0 { notices.failure = nil } })
        ) {
            Button {
                notices.failure = nil
            } label: {
                Text(app: "action.ok")
            }
        } message: {
            if let failure = notices.failure {
                Text(appKey: failure.messageKey)
            }
        }
    }
}
