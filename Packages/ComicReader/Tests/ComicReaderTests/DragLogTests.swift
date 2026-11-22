import CoreGraphics
import Foundation
import Testing

@testable import ComicReader

/// The drag log: what the finger did, what the strip did, and when that is conspicuous.
@Suite("Drag log")
@MainActor
struct DragLogTests {

    @Test("An ordinary drag: strip follows, rolls out - no warning, momentum from the offset")
    func ordinary() throws {
        let p = DragLog()
        p.offset(10_000, time: 0)
        _ = p.phase("Finger", page: 500, time: 0)
        p.finger(start: CGPoint(x: 200, y: 300), route: CGSize(width: 0, height: 300), time: 0.25, page: 500)
        for i in 0...10 { p.offset(10_000 - CGFloat(i) * 30, time: 0.15 + Double(i) * 0.01) }
        _ = p.phase("gleitet", page: 500, time: 0.25)
        p.offset(8_800, time: 1.2)
        let text = try #require(p.phase("ruht", page: 495, time: 1.2))
        #expect(!text.hasPrefix("⚠"))
        #expect(text.contains("x 200 y 300"))
        #expect(text.contains("3000 pt/s"))
        #expect(text.contains("p. 500 → 495"))
    }

    @Test("The finger drags, the strip stays put - even if the scroll view reports nothing")
    func stripDoesNotFollow() throws {
        let p = DragLog()
        p.offset(10_000, time: 0)
        p.finger(start: CGPoint(x: 180, y: 250), route: CGSize(width: 4, height: 260), time: 0.4, page: 500)
        let text = try #require(p.fingerEnd(page: 500, time: 0.45))
        #expect(text.hasPrefix("⚠ Strip did not follow the finger"))
    }

    @Test("Released firmly, the strip does not roll out")
    func doesNotRollOut() throws {
        let p = DragLog()
        p.offset(5_000, time: 0)
        _ = p.phase("Finger", page: 300, time: 0)
        p.finger(start: CGPoint(x: 200, y: 600), route: CGSize(width: 0, height: -200), time: 0.2, page: 300)
        for i in 0...10 { p.offset(5_000 + CGFloat(i) * 20, time: 0.1 + Double(i) * 0.01) }
        _ = p.phase("gleitet", page: 300, time: 0.2)
        let text = try #require(p.phase("ruht", page: 300, time: 0.3))
        #expect(text.contains("did not coast"))
    }

    @Test("A new finger during roll-out begins a new drag")
    func dragsInARow() throws {
        let p = DragLog()
        p.offset(10_000, time: 0)
        _ = p.phase("Finger", page: 500, time: 0)
        p.finger(start: CGPoint(x: 200, y: 300), route: CGSize(width: 0, height: 300), time: 0.2, page: 500)
        p.offset(9_700, time: 0.2)
        _ = p.phase("gleitet", page: 499, time: 0.2)
        p.offset(9_000, time: 0.5)
        let firstMatch = try #require(p.phase("Finger", page: 497, time: 0.5))
        #expect(!firstMatch.hasPrefix("⚠"))
        #expect(firstMatch.contains("p. 500 → 497"))
        #expect(p.breadcrumb?.pageStart == 497)
    }

    @Test("A tap is not a drag")
    func tip() {
        let p = DragLog()
        _ = p.phase("Finger", page: 1, time: 0)
        #expect(p.phase("ruht", page: 1, time: 0.1) == nil)
    }
}
