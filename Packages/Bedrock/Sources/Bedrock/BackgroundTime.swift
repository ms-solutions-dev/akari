#if canImport(UIKit)
    import UIKit
#endif

/// Asks iOS for time to finish a sync after the app leaves the screen.
///
/// Without it iOS suspends the app a few seconds after it goes to the background — the fetches
/// break off, nothing is written, and the next launch starts over (device report 02.11.: four to
/// five launches in a row fetched the whole Grimmory catalog). With it the app usually gets about
/// half a minute more. A no-op where there is no `UIApplication` (macOS tests).
@MainActor
public final class BackgroundTime {
    #if canImport(UIKit)
        private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    public init(_ name: String) {
        #if canImport(UIKit)
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        #endif
    }

    /// Gives the time back — at the latest when iOS takes it away (expiration handler).
    public func end() {
        #if canImport(UIKit)
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        #endif
    }
}
