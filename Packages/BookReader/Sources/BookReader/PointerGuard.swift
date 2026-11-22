import Foundation
import ReadiumNavigator

/// Remembers which source each tap came from - so the same finger is not counted twice.
///
/// Readium's EPUB navigator detects taps from TWO streams: from the `pointerdown`/`pointerup`
/// events of the web view (identifier an `Int`) and from the UIKit touches of the
/// responder chain (identifier an `ObjectIdentifier`). While the web view is still loading a chapter,
/// only the UIKit stream arrives; once it is ready, only the JS stream. In the transition both deliver
/// the same touch one after the other, and Readium reports two taps 80 to 350 ms
/// apart. Two taps in
/// the middle cancel each other out, the HUD seems to swallow the tap; at the edge they page
/// two pages. By time alone a duplicate and a quick second tap cannot be
/// told apart (measured: duplicate after 332 ms, real click after 581 ms).
///
/// Hence the guard counts by source: once the web view has delivered pointers, only
/// its taps count - UIKit taps are then stragglers of the same touch (or taps
/// the web view swallowed for a reason: link, selection). Before that, in the loading phase, the
/// UIKit taps count. At the transition the first web view tap shortly after a UIKit tap at
/// the same spot is the duplicate and is dropped. Two taps from the same source always count -
/// quick paging at the edge stays quick. What is dropped: taps while a chapter loads,
/// taps on the edge outside the web view with a fixed layout - and at the transition a real
/// second tap within 0.6 s at the same spot.
/// That is intended: a swallowed tap means "tap once more", a duplicate at the edge
/// skips a page without anyone noticing.
///
/// The guard listens as an observer after Readium's own tap recognizer. Because Readium
/// calls the delegate synchronously on `up`, it has already seen the `down` of the same pointer
/// and knows at the tap whether it came from UIKit or from the web view.
@MainActor
final class PointerGuard: InputObserving {
    /// How long and how near the first web view tap after a UIKit tap counts as a duplicate.
    static let frist: TimeInterval = 0.6
    static let proximity: CGFloat = 16

    /// Whether the last pointer pressed came from UIKit (otherwise from the web view).
    private(set) var lastNative = false
    /// Whether the web view has delivered pointers yet - from then on only the web view counts.
    private(set) var webViewAlive = false
    private var lastNativeTap: (place: CGPoint, time: Date)?

    /// Why a tap does not count.
    enum Rejection: String {
        case straggler = "UIKit straggler, the WebView delivers itself"
        case duplicate = "WebView duplicate of a UIKit tap"
    }

    /// Whether the tap at `place` counts - otherwise the reason.
    func check(_ place: CGPoint) -> Rejection? {
        let now = Date()
        if lastNative {
            guard !webViewAlive else { return .straggler }
            lastNativeTap = (place, now)
            return nil
        }
        if let native = lastNativeTap {
            lastNativeTap = nil
            if now.timeIntervalSince(native.time) < PointerGuard.frist,
                abs(native.place.x - place.x) < PointerGuard.proximity,
                abs(native.place.y - place.y) < PointerGuard.proximity
            {
                return .duplicate
            }
        }
        return nil
    }

    /// What the last tap came from - for the log.
    var source: String { lastNative ? "UIKit" : "WebView" }

    func didReceive(_ event: PointerEvent) async -> Bool {
        if event.phase == .down {
            lastNative = event.pointer.id.base is ObjectIdentifier
            if !lastNative { webViewAlive = true }
        }
        return false
    }

    func didReceive(_ event: KeyEvent) async -> Bool { false }
}
