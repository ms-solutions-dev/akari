import CoreGraphics
import Testing

@testable import ComicReader

/// The layout of the pages in the webtoon strip - exactly from the heights, as a long series has them:
/// ordinary pages and a landscape page of different height every ten pages.
@Suite("Strip layout")
struct StripLayoutTests {

    private let layout = StripLayout(heights: (1...1170).map { $0 % 10 == 0 ? 251 : 502 })

    @Test("Top edges sum the heights; page 455 lies exactly where the sum says")
    func topEdges() {
        #expect(layout.count == 1170)
        #expect(layout.topEdge(1) == 0)
        #expect(layout.topEdge(2) == 502)
        #expect(layout.topEdge(11) == CGFloat(9 * 502 + 251))
        let expected = (1..<455).reduce(CGFloat(0)) { $0 + ($1 % 10 == 0 ? 251 : 502) }
        #expect(layout.topEdge(455) == expected)
    }

    @Test("Which page lies at a point - also at the edges and behind the end")
    func pageAtPoint() {
        #expect(layout.page(at: 0) == 1)
        #expect(layout.page(at: 501.9) == 1)
        #expect(layout.page(at: 502) == 2)
        #expect(layout.page(at: layout.topEdge(455) + 1) == 455)
        #expect(layout.page(at: -40) == 1)
        #expect(layout.page(at: layout.totalHeight + 10) == 1171)
    }

    @Test("Visible pages between two points, clipped to the strip")
    func visible() {
        let y = layout.topEdge(455) + 100
        #expect(layout.pages(from: y, until: y + 852) == 455...456)
        #expect(layout.pages(from: y, until: y + 1000) == 455...457)
        #expect(layout.pages(from: layout.totalHeight - 10, until: layout.totalHeight + 900) == 1170...1170)
    }

    @Test("A spot survives recomputing for a different width")
    func fractionSurvivesWidth() {
        let y = layout.topEdge(300) + 125.5
        let (page, fraction) = layout.fraction(at: y)
        #expect(page == 300)
        let narrower = StripLayout(heights: (1...1170).map { $0 % 10 == 0 ? 216 : 432 })
        let new = narrower.point(page: page, fraction: fraction)
        #expect(narrower.page(at: new) == 300)
        #expect(abs((new - narrower.topEdge(300)) - 125.5 * 432 / 502) < 0.5)
    }
}
