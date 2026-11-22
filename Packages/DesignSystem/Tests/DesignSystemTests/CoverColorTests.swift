import CoreGraphics
import Testing

@testable import DesignSystem

/// The cover color from the image - without CoreImage (average over a small
/// bitmap). Counter-check: a gray cover does not glow.
@Suite("Cover color")
struct CoverColorTests {

    /// A single-color image, `edge` x `edge` pixels.
    private func image(_ r: UInt8, _ g: UInt8, _ b: UInt8, edge: Int = 90) -> CGImage {
        var points = [UInt8](repeating: 0, count: edge * edge * 4)
        for i in stride(from: 0, to: points.count, by: 4) {
            points[i] = r
            points[i + 1] = g
            points[i + 2] = b
            points[i + 3] = 255
        }
        let ctx = CGContext(
            data: &points, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    @Test("A red cover glows reddish, light and dark")
    func red() throws {
        let color = try #require(CoverColor.glow(from: image(200, 40, 30)))
        for value in [color.light, color.dark] {
            let r = (value >> 16) & 0xFF
            let g = (value >> 8) & 0xFF
            let b = value & 0xFF
            #expect(r > g && r > b, "Red dominates: \(String(value, radix: 16))")
        }
    }

    @Test("A gray cover does not glow - the caller takes the accent")
    func gray() {
        #expect(CoverColor.glow(from: image(120, 120, 120)) == nil)
    }
}
