import CoreGraphics
import Testing

@testable import BookReader

@Suite("Card zoom")
struct CardZoomTests {

    let size = CGSize(width: 300, height: 200)

    @Test("The spot under the fingers stays put when pinching")
    func pinch() {
        let finger = CGSize(width: 100, height: -50)
        let z = CardZoom.pinched(CardZoom(), factor: 2, finger: finger, size: size)
        #expect(z.scale == 2)
        // After the zoom the point `finger` lies at 2 * finger + offset - at finger again.
        #expect(z.offset.width + 2 * finger.width == finger.width)
        #expect(z.offset.height + 2 * finger.height == finger.height)
    }

    @Test("Never below 1, never above 4, never past the edge")
    func limits() {
        #expect(
            CardZoom.pinched(CardZoom(), factor: 0.3, finger: .zero, size: size).scale == 1)
        #expect(CardZoom.pinched(CardZoom(), factor: 12, finger: .zero, size: size).scale == 4)
        let z = CardZoom.dragged(
            CardZoom(scale: 2), around: CGSize(width: 900, height: -900), size: size)
        #expect(z.offset == CGSize(width: 150, height: -100))
        #expect(
            CardZoom.dragged(CardZoom(), around: CGSize(width: 50, height: 0), size: size).offset
                == .zero)
    }

    @Test("To a place: it moves to the center, rotated too")
    func onSpot() {
        let z = CardZoom.on(CGPoint(x: 0.75, y: 0.5), scale: 2, quarter: 0, size: size)
        #expect(z.offset == CGSize(width: -150, height: 0))
        // A quarter turn: what is on the right in the image is then at the bottom of the screen.
        let landscape = CardZoom.on(CGPoint(x: 0.75, y: 0.5), scale: 2, quarter: 1, size: size)
        #expect(landscape.offset.width == 0)
        #expect(landscape.offset.height < 0)
    }
}
