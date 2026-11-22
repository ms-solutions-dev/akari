import Foundation
import SourcesKit

/// What lies on the screen at once: one page or two side by side.
///
/// Pages are 1-based like in Komga. For a double spread `left` and
/// `right` are already resolved in reading direction: right-to-left reads page 3
/// on the right and page 2 on the left.
public enum Spread: Sendable, Hashable, Identifiable {
    case single(Int)
    case double(links: Int, right: Int)

    /// The identifier for scrolling: the first page in reading direction.
    public var id: Int { first }

    /// The first page in reading direction - the one the reading state names.
    public var first: Int {
        switch self {
        case .single(let s): s
        case .double(let l, let r): min(l, r)
        }
    }

    public var last: Int {
        switch self {
        case .single(let s): s
        case .double(let l, let r): max(l, r)
        }
    }

    public var pages: [Int] {
        switch self {
        case .single(let s): [s]
        case .double(let l, let r): [l, r]
        }
    }

    public func contains(_ page: Int) -> Bool { pages.contains(page) }
}

/// How a volume breaks into spreads - the one decision made before
/// display, not during it.
///
/// **Single page** is the normal case: phone, iPad in portrait, iPad in split view.
/// **Double spread** only when the caller says so (iPad landscape, wide enough, series
/// not switched off). Then: the cover stands alone, a landscape image stands alone
/// and is never paired, and pairing starts over after a landscape image - otherwise from
/// the first double spread on, every page would lie on the wrong half.
public struct PagePlan: Sendable, Hashable {

    public let spreads: [Spread]
    public let direction: ReadingDirection
    public let count: Int

    /// - Parameters:
    ///   - count: pages in the volume
    ///   - measures: the measures from the manifest, index 0 = page 1; shorter or empty
    ///     means: unknown, counts as portrait
    ///   - doubleSpread: two pages side by side where possible
    ///   - coverAlone: the first page stands alone - default on, because a cover
    ///     beside page 2 shifts the double spreads of the whole volume
    ///   - direction: resolves left/right of a double spread
    public init(
        count: Int, measures: [PageSize] = [], doubleSpread: Bool = false, coverAlone: Bool = true,
        direction: ReadingDirection = .rightToLeft
    ) {
        self.count = max(count, 0)
        self.direction = direction
        var list: [Spread] = []
        var page = 1
        func landscape(_ s: Int) -> Bool { s - 1 < measures.count && measures[s - 1].landscape }
        while page <= self.count {
            let alone = !doubleSpread || landscape(page) || (coverAlone && page == 1)
            let next = page + 1
            if alone || next > self.count || landscape(next) {
                list.append(.single(page))
                page += 1
            } else {
                list.append(
                    direction == .rightToLeft
                        ? .double(links: next, right: page) : .double(links: page, right: next))
                page += 2
            }
        }
        spreads = list
    }

    /// The manifest, overwritten by what was measured while decoding -
    /// an empty manifest is filled up to `count` (unknown = portrait).
    public static func merged(
        _ manifest: [PageSize], measured: [Int: PageSize], count: Int
    ) -> [PageSize] {
        guard !measured.isEmpty else { return manifest }
        var list = manifest
        if list.count < count {
            list += Array(repeating: PageSize(width: 0, height: 1), count: count - list.count)
        }
        for (page, mass) in measured where page >= 1 && page <= list.count { list[page - 1] = mass }
        return list
    }

    /// Whether a measure taken while decoding says something new - **otherwise it is dropped**.
    /// It is new if the manifest knows nothing for the page (Komga only carries
    /// measures after its image analysis) or reports a different aspect ratio; the
    /// loader downscales, so only the ratio counts, not the pixels.
    public static func worthMetering(_ mass: PageSize, page: Int, manifest: [PageSize]) -> Bool {
        guard page >= 1, page <= manifest.count else { return true }
        let known = manifest[page - 1]
        guard known.width > 0, known.height > 0, mass.width > 0, mass.height > 0 else { return true }
        let old = Double(known.height) / Double(known.width)
        let new = Double(mass.height) / Double(mass.width)
        return abs(new - old) / old > 0.01
    }

    /// The spread that shows a page - when switching single <-> double (rotating)
    /// the page stays, not the index.
    public func spread(with page: Int) -> Spread? {
        spreads.first { $0.contains(page) }
    }

    public func index(from spread: Spread) -> Int? {
        spreads.firstIndex(of: spread)
    }

    /// The spread after this one in reading direction, `nil` at the end.
    public func next(to spread: Spread) -> Spread? {
        guard let i = index(from: spread), i + 1 < spreads.count else { return nil }
        return spreads[i + 1]
    }

    public func previous(before spread: Spread) -> Spread? {
        guard let i = index(from: spread), i > 0 else { return nil }
        return spreads[i - 1]
    }

    /// The order for horizontal scrolling: right-to-left puts the first
    /// page at the far right, i.e. at the end of the row.
    public var flattened: [Spread] {
        direction == .rightToLeft ? spreads.reversed() : spreads
    }
}

/// Where a tap went: left, middle, right - 25 / 50 / 25, mirrored
/// for right-to-left so that **forward** always lies in
/// reading direction.
public enum TapZone: Sendable, Hashable {
    case back, hud, before

    public static func `for`(x: CGFloat, width: CGFloat, direction: ReadingDirection) -> TapZone {
        guard width > 0 else { return .hud }
        let fraction = x / width
        let layout: TapZone = fraction < 0.25 ? .back : fraction > 0.75 ? .before : .hud
        guard direction == .rightToLeft else { return layout }
        switch layout {
        case .back: return .before
        case .before: return .back
        case .hud: return .hud
        }
    }
}

/// Which pages around the shown one should already be fetched.
///
/// At home 3 back and 5 ahead, on the road +-3 - through the tunnel every page
/// takes half a minute, and five ahead would be two minutes of line for pages that
/// may never come. Beyond the volume boundary (`nextVolume`) only
/// at home, and only from five pages before the end.
public enum Preload {

    /// In the webtoon (`vertical`) a page is a short piece of the strip and gone in
    /// one swipe - a long series has 1170 pages of 800 x 1000 per volume,
    /// five ahead would be one thumb movement. Hence 20 ahead there, 10 on the road.
    ///
    /// **Backwards the window applies upwards** (`backwards`): whoever scrolled up in the webtoon
    /// after continuing at page 500 had only three pages prepared, every
    /// further one stood black until it came from the server.
    ///
    /// **In the webtoon in screen heights, not pages** (`width`):
    /// dragged narrower every page gets lower, at 50 % twice as many stand on the
    /// screen - twenty pages of stock would be only ten screens. The window therefore grows
    /// with the reciprocal of the width (at most 60 pages).
    public static func window(
        around page: Int, count: Int, atHome: Bool, vertical: Bool = false, backward: Bool = false,
        width: Double = 1
    ) -> ClosedRange<Int> {
        guard count > 0 else { return 1...1 }
        let atBack = 3
        let pages = vertical ? (atHome ? 20 : 10) : (atHome ? 5 : 3)
        let front =
            vertical && width < 1 ? min(Int((Double(pages) / max(width, 0.25)).rounded(.up)), 60) : pages
        let (before, after) = backward && vertical ? (front, atBack) : (atBack, front)
        return max(1, page - before)...min(count, page + after)
    }

    /// How many pages of the next volume come ahead - 0 if none.
    public static func nextVolume(page: Int, count: Int, atHome: Bool) -> Int {
        guard atHome, count > 0, page >= count - 5 else { return 0 }
        return 3
    }
}
