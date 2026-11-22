import CoreGraphics
import Testing

@testable import BookReader

/// In scroll mode a clear, long downward drag closes - no scrolling, no diagonal drag.
@Suite("Top pull")
@MainActor
struct TopPullTests {

    @Test("Far enough and clearly downward closes, everything else does not")
    func closes() {
        #expect(TopPull.closes(CGPoint(x: 10, y: 160)))
        #expect(!TopPull.closes(CGPoint(x: 0, y: 80)))  // too short
        #expect(!TopPull.closes(CGPoint(x: 120, y: 160)))  // diagonal
        #expect(!TopPull.closes(CGPoint(x: 0, y: -300)))  // upward: scrolling
    }
}
