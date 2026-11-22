import CoreGraphics

/// Where each page lies in the webtoon strip - computed from the known heights, not estimated.
///
/// **Why not a LazyVStack**: the LazyVStack does not know the
/// height of pages it has not built yet and estimates it. When scrolling up after
/// jumping to page 455 it rebuilt every page above, each deviated from the estimate, and
/// SwiftUI pushed the content back under the finger to compensate: 2,100 pt scrolled, the same
/// page ("I drag, nothing happens"). The same estimate made the jump on
/// opening land ten pages off. But the reader knows the heights beforehand (Komga's page list,
/// ``MeasureStore``) - so the strip places every page at its spot itself and builds only the ones to
/// be seen.
struct StripLayout: Equatable {

    /// The top edge of each page; `top[0]` is page 1, the last entry the end of the last.
    let top: [CGFloat]

    init(heights: [CGFloat]) {
        var sum: CGFloat = 0
        var edges: [CGFloat] = [0]
        edges.reserveCapacity(heights.count + 1)
        for h in heights {
            sum += max(h, 1)
            edges.append(sum)
        }
        top = edges
    }

    var count: Int { top.count - 1 }

    /// The height of all pages together - behind it lies the volume-end sheet.
    var totalHeight: CGFloat { top.last ?? 0 }

    func topEdge(_ page: Int) -> CGFloat {
        top[min(max(page, 1), max(count, 1)) - 1]
    }

    func height(_ page: Int) -> CGFloat {
        guard page >= 1, page <= count else { return 0 }
        return top[page] - top[page - 1]
    }

    /// The page containing `y` (1-based); behind the last `count + 1` - the end sheet.
    func page(at y: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        if y >= totalHeight { return count + 1 }
        if y < 0 { return 1 }
        var bottom = 0
        var topIndex = count - 1
        while bottom < topIndex {
            let center = (bottom + topIndex + 1) / 2
            if top[center] <= y { bottom = center } else { topIndex = center - 1 }
        }
        return bottom + 1
    }

    /// The pages lying between `from` and `until` (points in the strip) - clipped to the strip.
    func pages(from: CGFloat, until: CGFloat) -> ClosedRange<Int> {
        guard count > 0 else { return 1...1 }
        let first = min(page(at: from), count)
        let last = min(page(at: max(until, from)), count)
        return first...max(first, last)
    }

    /// How far `y` reaches into its page, as a fraction of its height - so that after recomputing
    /// (new width, late measure) the same spot stays on top.
    func fraction(at y: CGFloat) -> (page: Int, fraction: CGFloat) {
        let s = min(page(at: y), max(count, 1))
        let h = height(s)
        return (s, h > 0 ? min(max((y - topEdge(s)) / h, 0), 1) : 0)
    }

    func point(page: Int, fraction: CGFloat) -> CGFloat {
        topEdge(page) + height(page) * fraction
    }
}

/// What the strip reports while scrolling: the topmost visible spot and the scroller's offset -
/// their difference is the inset at the top (status bar), which a jump must subtract.
struct StripViewport: Equatable {
    let top: CGFloat
    let offset: CGFloat
}

/// Where the strip stands - page and fraction in it. A class without observation: it changes with
/// every image, an `@State` for it rebuilt the whole reader per image.
@MainActor
final class StripState {
    private(set) var page = 1
    private(set) var fraction: CGFloat = 0
    var indent: CGFloat = 0

    func save(_ state: (page: Int, fraction: CGFloat)) {
        page = state.page
        fraction = state.fraction
    }

    /// A jump: afterwards the start of this page is on top.
    func target(page new: Int) {
        page = new
        fraction = 0
    }
}
