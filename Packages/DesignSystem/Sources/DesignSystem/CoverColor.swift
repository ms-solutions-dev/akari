import CoreGraphics
import Foundation
import Synchronization

/// The color a cover casts into the room ("the heart of depth").
///
/// The average over the middle third is computed, then limited in
/// brightness and saturation: in light a colored hint (light, low saturation),
/// in dark a glow (muted). Text never sits directly on the glow but on
/// paper - the contrasts stay valid.
///
/// The reference computes in OKLCH; here it is HSB with fixed limits. That is simpler and
/// equivalent enough for a soft glow - an exact OKLCH match only pays off
/// when colors are compared side by side.
///
public enum CoverColor {

    /// The glow color of a cover - `nil` for gray covers (saturation under 8 %); then
    /// the caller takes the theme's accent.
    ///
    /// Without CoreImage: draw the middle third into a 16x16 bitmap and average. Before,
    /// `CIAreaAverage` computed on the main thread - for the first cover including Metal startup, for
    /// every further one a GPU round trip, in the middle of the zoom into the detail (stutter).
    /// So it is about a millisecond.
    ///
    /// Remembered per image: hero, detail and cap ask for the same cover, already
    /// in the first frame - then it should not be recomputed every time. The image itself
    /// stays in the memo so its identity is not handed to a new image.
    public static func glow(from image: CGImage) -> AdaptiveColor? {
        let identifier = ObjectIdentifier(image)
        if let saved = memo.withLock({ $0.first { $0.identifier == identifier } }) {
            return saved.color
        }
        let color = computed(from: image)
        memo.withLock { list in
            list.append(Coordinator(identifier: identifier, image: image, color: color))
            if list.count > 48 { list.removeFirst(list.count - 48) }
        }
        return color
    }

    private struct Coordinator: @unchecked Sendable {
        let identifier: ObjectIdentifier
        let image: CGImage
        let color: AdaptiveColor?
    }

    private static let memo = Mutex<[Coordinator]>([])

    private static func computed(from image: CGImage) -> AdaptiveColor? {
        let b = image.width / 3
        let h = image.height / 3
        guard b > 0, h > 0, let center = image.cropping(to: CGRect(x: b, y: h, width: b, height: h)) else {
            return nil
        }
        let edge = 16
        var points = [UInt8](repeating: 0, count: edge * edge * 4)
        let painted = points.withUnsafeMutableBytes { storage -> Bool in
            guard
                let ctx = CGContext(
                    data: storage.baseAddress, width: edge, height: edge, bitsPerComponent: 8,
                    bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(center, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard painted else { return nil }
        var sum = (0, 0, 0)
        for i in stride(from: 0, to: points.count, by: 4) {
            sum.0 += Int(points[i])
            sum.1 += Int(points[i + 1])
            sum.2 += Int(points[i + 2])
        }
        let n = Double(edge * edge) * 255
        return glow(red: Double(sum.0) / n, green: Double(sum.1) / n, blue: Double(sum.2) / n)
    }

    /// From an average the two glow colors - kept separate so `CoverColorTests`
    /// can compute without an image.
    static func glow(red: Double, green: Double, blue: Double) -> AdaptiveColor? {
        let (audio, saturation, _) = hsb(red, green, blue)
        guard saturation >= 0.08 else { return nil }
        let light = rgb(audio, min(saturation, 0.30), 0.93)
        let dark = rgb(audio, min(saturation, 0.45), 0.40)
        return AdaptiveColor(light: hex(light), dark: hex(dark))
    }

    static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let span = maximum - minimum
        var audio = 0.0
        if span > 0 {
            if maximum == r {
                audio = ((g - b) / span).truncatingRemainder(dividingBy: 6)
            } else if maximum == g {
                audio = (b - r) / span + 2
            } else {
                audio = (r - g) / span + 4
            }
            audio /= 6
            if audio < 0 { audio += 1 }
        }
        return (audio, maximum == 0 ? 0 : span / maximum, maximum)
    }

    static func rgb(_ audio: Double, _ saturation: Double, _ brightness: Double) -> (Double, Double, Double) {
        let h = audio * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    static func hex(_ color: (Double, Double, Double)) -> UInt32 {
        func channel(_ w: Double) -> UInt32 { UInt32((min(max(w, 0), 1) * 255).rounded()) }
        return channel(color.0) << 16 | channel(color.1) << 8 | channel(color.2)
    }
}
