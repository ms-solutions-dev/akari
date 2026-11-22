import Foundation
import Synchronization

/// **Whoever wants to read along with the sessions' network requests** hooks in here — the
/// app's performance diagnostics. SourcesKit does not know them; it passes on the start and
/// end of every request via ``Transport/send(_:)`` together with `URLSessionTaskMetrics`.
///
/// **As delegate of the task, not of the session:** the async methods of `URLSession` attach
/// their own delegate to every task, and it takes the task's callbacks before the session
/// delegate sees them — `didCompleteWithError` never arrived there. A ``Collector`` per request,
/// passed along with the method, receives `didCreateTask` and the metrics; **it does not get the
/// completion either** (`didCompleteWithError` stays with the async method's inner delegate), so
/// ``Transport/send(_:)`` reports it itself with ``Collector/complete(failure:)``. The
/// certificate callback still falls through to the session's watch.
///
/// Without a listener it costs one mutex look per request.
public enum NetworkObservation {

    public struct Listener: Sendable {
        public let begun: @Sendable (URLSessionTask) -> Void
        public let finished: @Sendable (URLSessionTask, URLSessionTaskMetrics?, (any Error)?) -> Void

        public init(
            begun: @escaping @Sendable (URLSessionTask) -> Void,
            finished: @escaping @Sendable (URLSessionTask, URLSessionTaskMetrics?, (any Error)?) -> Void
        ) {
            self.begun = begun
            self.finished = finished
        }
    }

    private static let listener = Mutex<Listener?>(nil)

    /// Sets the listener — `nil` removes it.
    public static func set(_ new: Listener?) {
        listener.withLock { $0 = new }
    }

    /// A collector for the next request — `nil` if nobody is listening.
    static func collector() -> Collector? {
        listener.withLock { $0 }.map(Collector.init)
    }

    /// Takes task and metrics and reports both once the caller names
    /// the completion. A completion without a prior `didCreateTask` reports the start
    /// afterwards, so that start and end stay paired at the listener.
    final class Collector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private struct Phase {
            var task: URLSessionTask?
            var metrics: URLSessionTaskMetrics?
            var begun = false
        }

        private let listener: Listener
        private let phase = Mutex(Phase())

        init(listener: Listener) {
            self.listener = listener
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            phase.withLock {
                $0.task = task
                $0.begun = true
            }
            listener.begun(task)
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            phase.withLock {
                $0.task = task
                $0.metrics = metrics
            }
        }

        /// The caller says how it ended — `nil` means: response received.
        func complete(failure: (any Error)?) {
            let (task, metrics, begun) = phase.withLock { ($0.task, $0.metrics, $0.begun) }
            guard let task else { return }
            if !begun { listener.begun(task) }
            listener.finished(task, metrics, failure)
        }
    }
}
