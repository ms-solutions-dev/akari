import Synchronization
import Testing

@testable import Bedrock

/// The gate in front of the heavy start work: open unless the lantern holds it, and whoever
/// waits goes on when it is released.
@Suite("Launch quiet", .serialized)
@MainActor
struct LaunchQuietTests {

    @Test("Open by default: waiting returns at once")
    func openByDefault() async {
        LaunchQuiet.release()
        await LaunchQuiet.wait()
    }

    @Test("Held: waiting goes on only after release")
    func heldUntilRelease() async throws {
        LaunchQuiet.hold()
        let passed = Mutex(false)
        let waiter = Task { @MainActor in
            await LaunchQuiet.wait()
            passed.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!passed.withLock { $0 }, "still held")
        LaunchQuiet.release()
        await waiter.value
        #expect(passed.withLock { $0 })
    }
}
