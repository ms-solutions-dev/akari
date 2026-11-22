import Foundation
import Testing

@testable import Bedrock

/// **A cancellation is not an error:** in the always-on error log, "Fetch ratings ✗
/// network error -999" appeared seven times per scroll, and "Portal request
/// unreachable: network error -999".
@Suite("Cancellations in the log")
struct CancellationTests {

    @Test("What counts as a cancellation: -999, CancellationError, and the same as an NSError")
    func detection() {
        #expect(Diagnostics.isCancellation(URLError(.cancelled)))
        #expect(Diagnostics.isCancellation(CancellationError()))
        #expect(Diagnostics.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(!Diagnostics.isCancellation(URLError(.timedOut)))
        #expect(!Diagnostics.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    /// **Checked against the shared trace this would be a race** with the other
    /// suites that empty it; the decision is therefore a computation. The counter
    /// test against the old code ran via ``Diagnostics/failure(_:step:error:)`` and
    /// the trace itself.
    @Test("A cancelled request leaves no failure, a real one does")
    func traceOutcome() {
        #expect(Diagnostics.traceOutcome(for: URLError(.cancelled), recording: false) == nil)
        #expect(
            Diagnostics.traceOutcome(for: URLError(.cancelled), recording: true)
                == .succeeded("cancelled"))
        guard
            case .failed(let reason)? = Diagnostics.traceOutcome(
                for: URLError(.timedOut), recording: false)
        else {
            Issue.record("Timeout without failure")
            return
        }
        #expect(reason.hasPrefix("Timed out"))
    }

    @Test("A deficiency with an error: no sentence if cancelled, otherwise with the translated cause")
    func deficiencySentence() {
        #expect(
            Diagnostics.deficiencySentence("Portal request unreachable", failure: URLError(.cancelled))
                == nil)
        #expect(
            Diagnostics.deficiencySentence("Portal request unreachable", failure: URLError(.timedOut))?
                .hasPrefix("Portal request unreachable: Timed out") == true)
    }

    @Test("The translation names -999 instead of \"Network error -999\"")
    func explanation() {
        #expect(Diagnostics.explain(URLError(.cancelled)).hasPrefix("Cancelled (-999)"))
    }
}
