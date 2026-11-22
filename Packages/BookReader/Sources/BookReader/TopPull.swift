import UIKit

/// **Pulling down from the very top closes the reader - in scroll mode.**
///
/// In scroll mode the downward drag belongs to the text, so the shell's close drag is
/// locked there (``CloseGestureLocked``). But when the text is at the very top there is nothing
/// left to scroll, and the same drag should close - as known from full-screen views.
///
/// **Beside Readium, not instead of it**: a recognizer of its own on the navigator's view,
/// running at the same time as scrolling and intercepting nothing. On touch-down it notes whether the
/// scroll view under the finger is at the top; at the end only a clear, long downward drag counts.
/// Readium creates its own web view per chapter - hence the scroll view is looked up under
/// the finger every time, not once upfront.
@MainActor
final class TopPull: NSObject, UIGestureRecognizerDelegate {

    /// How far down until it closes.
    static let from: CGFloat = 130

    private let recognizer = UIPanGestureRecognizer()
    private let active: () -> Bool
    private let trigger: () -> Void
    private var topAtTouchDown = false

    init(to hostView: UIView, active: @escaping () -> Bool, trigger: @escaping () -> Void) {
        self.active = active
        self.trigger = trigger
        super.init()
        recognizer.addTarget(self, action: #selector(breadcrumb(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        hostView.addGestureRecognizer(recognizer)
    }

    nonisolated func gestureRecognizer(
        _: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool { true }

    /// Whether a drag closes: far enough down and at least twice as far as sideways.
    static func closes(_ route: CGPoint) -> Bool {
        route.y >= from && abs(route.x) * 2 <= route.y
    }

    @objc private func breadcrumb(_ e: UIPanGestureRecognizer) {
        guard let hostView = e.view, active() else { return }
        switch e.state {
        case .began:
            let scroller = TopPull.scrollerView(below: e.location(in: hostView), in: hostView)
            topAtTouchDown = scroller.map { $0.contentOffset.y <= -$0.adjustedContentInset.top + 2 } ?? false
        case .ended:
            if topAtTouchDown, TopPull.closes(e.translation(in: hostView)) { trigger() }
            topAtTouchDown = false
        case .cancelled, .failed:
            topAtTouchDown = false
        default:
            break
        }
    }

    /// The innermost scroll view under the point - the chapter's web view.
    private static func scrollerView(below point: CGPoint, in hostView: UIView) -> UIScrollView? {
        var v = hostView.hitTest(point, with: nil)
        while let now = v {
            if let r = now as? UIScrollView, r.isScrollEnabled, r.contentSize.height > r.bounds.height {
                return r
            }
            v = now.superview
        }
        return nil
    }
}
