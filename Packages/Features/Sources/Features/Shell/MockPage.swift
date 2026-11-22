import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A drawn manga page for the preview with mocks: paper, four panels with hairline, a
/// few speech bubbles, 1000 x 1500 pixels like a real page in the library.
enum MockPage {

    static func jpeg() -> Data {
        let width = 1000
        let height = 1500
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return Data() }
        context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        context.setLineWidth(5)
        let panels = [
            CGRect(x: 60, y: 60, width: 880, height: 560),
            CGRect(x: 60, y: 660, width: 420, height: 380),
            CGRect(x: 520, y: 660, width: 420, height: 380),
            CGRect(x: 60, y: 1080, width: 880, height: 360),
        ]
        for panel in panels {
            context.setFillColor(CGColor(gray: 0.82, alpha: 1))
            context.fill(panel)
            context.stroke(panel)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for bubble in [
            CGRect(x: 640, y: 120, width: 240, height: 140), CGRect(x: 120, y: 700, width: 220, height: 120),
            CGRect(x: 600, y: 1120, width: 260, height: 150),
        ] {
            context.fillEllipse(in: bubble)
            context.strokeEllipse(in: bubble)
        }
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(
            target, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(target)
        return data as Data
    }
}
