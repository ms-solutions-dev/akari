import Foundation
import Observation
import SourcesKit

/// The ``NetworkSpeed`` on the main thread, fed by the ``MeteringTransport`` before each
/// image and page request, read by the status banner: "Slow connection, ~0.3
/// Mbit/s". Lives in the shell like the network watch; when that switches path, the
/// measurement is forgotten.
@MainActor
@Observable
final class NetworkMeter {

    /// The measurement itself is not observed: it changes with every loaded cover,
    /// and every change made the status banner on Start recompute.
    /// Only the state and the rounded rate are observed, and those rarely change.
    @ObservationIgnored private var tempo = NetworkSpeed()

    /// What the line currently carries: ``NetworkStatus/slow(mbit:)`` or reachable.
    private(set) var phase: NetworkStatus = NetworkSpeed().phase

    /// The measured rate in megabits per second, rounded to a tenth; `nil` before the
    /// second measurement.
    private(set) var mbit: Double?

    func save(bytes: Int, startTime: TimeInterval, end: TimeInterval) {
        tempo.save(bytes: bytes, startTime: startTime, end: end)
        adopt()
    }

    func forget() {
        tempo.forget()
        hidden = false
        adopt()
    }

    /// "Hide" on the banner: gone until the line was good again and becomes slow once more.
    private(set) var hidden = false

    func fadeOut() { hidden = true }

    private func adopt() {
        // Compared rounded: `.slow(mbit:)` carries the raw rate and would otherwise differ after every
        // cover, exactly on a slow line where that costs the most.
        var new = tempo.phase
        if case .slow(let rate) = new { new = .slow(mbit: (rate * 10).rounded() / 10) }
        if new != phase {
            if new == .reachable { hidden = false }
            phase = new
        }
        let rounded = tempo.mbit.map { ($0 * 10).rounded() / 10 }
        if rounded != mbit { mbit = rounded }
    }

    /// The callback for a ``MeteringTransport``, callable from any thread.
    nonisolated var report: @Sendable (Int, TimeInterval, TimeInterval) -> Void {
        { [self] bytes, startTime, end in
            Task { @MainActor in self.save(bytes: bytes, startTime: startTime, end: end) }
        }
    }
}
