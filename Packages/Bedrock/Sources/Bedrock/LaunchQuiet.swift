/// Holds heavy start work back while the launch animation runs.
///
/// Device report 02.11.: in the lantern's first second only 5 of 60 frames were drawn — the
/// whole catalog (30 MB of JSON, memory 46 → 341 MB) was decoding at the same time, and the
/// iPhone has only two performance cores. Work that the start page does not need waits
/// here until the lantern is out (``release()``), at most ``limit``.
///
/// Open by default: tests, screenshots and launches without the lantern never wait.
@MainActor
public enum LaunchQuiet {
    private static var held = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    /// The longest the hold lasts, whatever happens to the animation.
    public static let limit: Duration = .seconds(2.5)

    /// Closes the gate — the app calls it when it shows the lantern.
    public static func hold() {
        held = true
        Task {
            try? await Task.sleep(for: limit)
            release()
        }
    }

    /// Opens the gate; everything waiting goes on.
    public static func release() {
        held = false
        let all = waiting
        waiting = []
        for w in all { w.resume() }
    }

    /// Returns at once while the gate is open, otherwise when it opens.
    public static func wait() async {
        guard held else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}
