import Bedrock
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

extension View {
    /// The probe for the Regular to Compact change (Split View, Slide Over), which the
    /// simulator cannot trigger: `AKARI_KOMPAKT=<seconds>` forces the window into the
    /// narrow size class for eight seconds, that many seconds after launch, and then
    /// lets it go back, enough for one screenshot before, during and after. What must
    /// survive: the selected tab, the stack (an open detail), the scroll position.
    ///
    /// It works through the **UIKit traits** of the root controller, not the SwiftUI
    /// environment: the tabs are a `UITabBarController`, which hands its contents the
    /// size class from its own trait collection, so a `transformEnvironment` above it
    /// never arrived below. Without the variable the modifier does nothing.
    public func sizeClassProbe() -> some View {
        modifier(SizeClassProbeModifier())
    }
}

private struct SizeClassProbeModifier: ViewModifier {

    func body(content: Content) -> some View {
        content
            .task {
                guard let seconds = Int(ProcessInfo.processInfo.environment["AKARI_KOMPAKT"] ?? "")
                else { return }
                try? await Task.sleep(for: .seconds(seconds))
                SizeClassProbeModifier.force(.compact)
                try? await Task.sleep(for: .seconds(8))
                SizeClassProbeModifier.force(.regular)
            }
    }

    @MainActor
    private static func force(_ sizeClass: UserInterfaceSizeClass) {
        #if canImport(UIKit) && !os(watchOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for window in scenes.flatMap(\.windows) {
                window.rootViewController?.traitOverrides.horizontalSizeClass =
                    sizeClass == .compact ? .compact : .regular
                Diagnostics.step(
                    "Size class probe: \(window) -> \(sizeClass) root=\(String(describing: window.rootViewController))",
                    since: nil, area: "Probe")
            }
        #endif
    }
}
