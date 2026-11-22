import BookReader
import Features
import SwiftUI

/// Plugs the book reader into the shell: `Features` knows it only as a
/// ``ReaderFactory`` in the environment, because Readium does not support macOS; here, in the
/// app target, both meet - field by field from the ``BookJob`` to the ``ReaderBook``.
extension View {
    func withBookReader() -> some View {
        environment(\.bookReader) { job in
            AnyView(BookReaderView(book: job.asReaderBook))
        }
        .environment(\.inBook) { id, file in
            InBookPage.present(file) ? AnyView(InBookPage(id: id, file: file)) : nil
        }
    }
}

extension BookJob {
    fileprivate var asReaderBook: ReaderBook {
        ReaderBook(
            id: id, name: name, subline: subline, file: file, start: start, keep: keep,
            report: report, requestKeep: requestKeep,
            continuation: continuation.map {
                ReaderBook.Continuation(
                    kind: $0.kind == .nextVolume ? .nextVolume : .saved, name: $0.name,
                    subline: $0.subline, open: $0.open)
            },
            toSeries: toSeries)
    }
}
