import Bedrock
import Foundation

/// What happens once at start, before the first screen stands.
enum AppLaunch {

    /// Crash guard, recording switch, state mark - in this order, so
    /// the state mark already finds the crash of the previous run.
    @MainActor
    static func launch() {
        CrashGuard.install()
        DebugMode.activate(from: SecureStore())
        // Bedrock knows neither engine nor decoder - the line stays empty until the
        // sources are there; then it states how many and which.
        Diagnostics.noteLaunch(extra: [])
        MemoryWatch.start()
    }
}
