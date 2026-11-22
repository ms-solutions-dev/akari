import CoreGraphics
import Foundation

/// What a drag in the webtoon strip did - for diagnostics ("when I
/// drag down I move at the spot, nothing happens, it hangs").
///
/// Recorded: **where the finger touched down** (point on screen), **how far it dragged**,
/// **how far the strip went along**, **with what momentum** it was released, **how far
/// it rolled out afterwards** and **on which page it landed**. Two patterns are flagged:
/// the finger dragged and the strip stayed put; or it was released firmly and the strip
/// did not roll out.
///
/// **No observed state**: the offset arrives with every image, an `@State` for it would be a
/// rebuild of the whole reader per image. The class collects quietly and reports once per drag.
@MainActor
final class DragLog {

    /// From this much finger travel a drag counts, below that it is a tap.
    static let fingerFrom: CGFloat = 40
    /// If the strip follows less than this share of the finger travel, it did not follow.
    static let followsFrom: CGFloat = 0.25
    /// From this momentum on release a roll-out is expected.
    static let momentumFrom: CGFloat = 500
    /// If the strip then rolls less than that, it did not roll out.
    static let rollOutFrom: CGFloat = 40

    struct Drag: Equatable {
        var startTime: TimeInterval
        var offsetStart: CGFloat
        var pageStart: Int
        var fingerStart: CGPoint?
        var fingerTravel: CGSize = .zero
        var fingerTime: TimeInterval = 0
        var release: TimeInterval?
        var offsetRelease: CGFloat?
        var momentum: CGFloat = 0
        /// Whether the scroll view recognized the drag as scrolling at all.
        var flattened = false
    }

    private(set) var breadcrumb: Drag?
    private var offset: CGFloat = 0
    private var samples: [(time: TimeInterval, offset: CGFloat)] = []

    /// The offset of the strip - with every image while recording runs.
    func offset(_ y: CGFloat, time: TimeInterval) {
        offset = y
        samples.append((time, y))
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
    }

    /// The finger, from the drag beside scrolling. Also begins a drag when the scroll view
    /// reports none - exactly the case "I drag and nothing happens".
    /// If the finger touches down again while the strip is still rolling out from the previous drag,
    /// the previous one is finished - its text comes back.
    @discardableResult
    func finger(start: CGPoint, route: CGSize, time: TimeInterval, page: Int) -> String? {
        var previous: String?
        if let old = breadcrumb, old.release != nil, old.fingerStart != start {
            previous = finish(old, page: page, time: time)
        }
        var z = breadcrumb ?? Drag(startTime: time, offsetStart: offset, pageStart: page)
        z.fingerStart = z.fingerStart ?? start
        z.fingerTravel = route
        z.fingerTime = time
        breadcrumb = z
        return previous
    }

    private func finish(_ old: Drag, page: Int, time: TimeInterval) -> String? {
        breadcrumb = nil
        return DragLog.text(old, offsetEnd: offset, pageEnd: page, end: time)
    }

    /// The finger is up. If the scroll view did not scroll along, the drag ends here;
    /// otherwise it ends when it rests again.
    func fingerEnd(page: Int, time: TimeInterval) -> String? {
        guard let done = breadcrumb, !done.flattened else { return nil }
        breadcrumb = nil
        var z = done
        z.release = time
        z.offsetRelease = offset
        return DragLog.text(z, offsetEnd: offset, pageEnd: page, end: time)
    }

    /// A phase change of scrolling. At the end of a drag (rest again) the text for the
    /// diagnostics comes back.
    func phase(_ new: String, page: Int, time: TimeInterval) -> String? {
        switch new {
        case "Finger":
            var previous: String?
            if let old = breadcrumb, old.release != nil { previous = finish(old, page: page, time: time) }
            if breadcrumb == nil {
                breadcrumb = Drag(startTime: time, offsetStart: offset, pageStart: page)
            }
            breadcrumb?.flattened = true
            return previous
        case "gleitet", "springt":
            if breadcrumb != nil, breadcrumb?.release == nil { released(time) }
            return nil
        case "ruht":
            guard var done = breadcrumb else { return nil }
            breadcrumb = nil
            if done.release == nil {
                done.release = time
                done.offsetRelease = offset
            }
            return DragLog.text(done, offsetEnd: offset, pageEnd: page, end: time)
        default:
            return nil
        }
    }

    private func released(_ time: TimeInterval) {
        breadcrumb?.release = time
        breadcrumb?.offsetRelease = offset
        breadcrumb?.momentum = DragLog.momentum(samples, until: time)
    }

    /// Points per second from the last 100 ms before release - SwiftUI delivers no
    /// velocity on the phase change (the report always said "0 pt/s").
    static func momentum(
        _ samples: [(time: TimeInterval, offset: CGFloat)], until time: TimeInterval
    ) -> CGFloat {
        let window = samples.filter { $0.time >= time - 0.1 && $0.time <= time }
        guard let first = window.first, let last = window.last, last.time - first.time > 0.008 else {
            return 0
        }
        return (last.offset - first.offset) / CGFloat(last.time - first.time)
    }

    /// One sentence per drag; conspicuous ones start with "⚠". The finger downward means strip upward -
    /// hence ``followed`` compares magnitudes, not signs.
    static func text(_ z: Drag, offsetEnd: CGFloat, pageEnd: Int, end: TimeInterval) -> String? {
        let finger = abs(z.fingerTravel.height)
        let dragged = abs((z.offsetRelease ?? offsetEnd) - z.offsetStart)
        let rolledOut = abs(offsetEnd - (z.offsetRelease ?? offsetEnd))
        guard finger >= fingerFrom || dragged >= fingerFrom else { return nil }
        var warnings: [String] = []
        if finger >= fingerFrom, dragged < finger * followsFrom {
            warnings.append("Strip did not follow the finger")
        }
        if abs(z.momentum) >= momentumFrom, rolledOut < rollOutFrom { warnings.append("did not coast") }
        let direction = z.fingerTravel.height >= 0 ? "↓" : "↑"
        let start = z.fingerStart.map { String(format: "x %.0f y %.0f", $0.x, $0.y) } ?? "?"
        let dragDuration = (z.release ?? end) - z.startTime
        let phrase = String(
            format:
                "Finger at %@, %.0f pt %@ in %.2f s · strip while dragging %.0f pt · released at %.0f pt/s · coasted %.0f pt in %.2f s · p. %d → %d",
            start, finger, direction, dragDuration, dragged, abs(z.momentum), rolledOut,
            end - (z.release ?? end),
            z.pageStart, pageEnd)
        return warnings.isEmpty ? phrase : "⚠ " + warnings.joined(separator: ", ") + " — " + phrase
    }
}
