import CoreGraphics
import ImageIO
import SwiftUI

/// The app icon as a brand mark in the header of the start page - instead of a
/// "Start" heading. Light and dark as separate
/// versions of the app icon, rasterized to 192 px; the view rounds the corners itself
/// so the icon looks as on the home screen.
public struct Brand: View {

    private let edge: CGFloat

    /// - Parameter edge: the side length in points.
    public init(edge: CGFloat = 32) {
        self.edge = edge
    }

    @Environment(\.colorScheme) private var schema

    public var body: some View {
        Group {
            if let image = Brand.image(dark: schema == .dark) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "books.vertical.fill")
            }
        }
        .frame(width: edge, height: edge)
        .clipShape(RoundedRectangle(cornerRadius: edge * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }

    private static let light = load("marke")
    private static let dark = load("marke-dunkel")

    static func image(dark: Bool) -> CGImage? {
        dark ? Brand.dark ?? Brand.light : Brand.light
    }

    /// An image from `Marke/` - also for ``LanternStart``.
    nonisolated static func load(_ name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Marke"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        // Decoded right here, not on the first draw: otherwise the lantern's first frame paid
        // for two PNGs on the main thread (device report 02.11.: 83 ms).
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// The header of the start page: mark and name, in the serif, where
/// the large title would otherwise be.
public struct BrandHeader: View {

    public init() {}

    public var body: some View {
        // The mark is the tip of the page - as large as the title it
        // replaces: mark 34,
        // word 28 pt in the serif, medium like a page title.
        // Mark 44 pt - the same height as the glass circle of the account on the right, otherwise
        // it looks small beside it; the word on the same
        // center, the serif visually lowered by a point because its ascenders
        // lie above the middle.
        HStack(alignment: .center, spacing: 10) {
            Brand(edge: 44)
            Text(verbatim: "Akari")
                .font(Typography.title(.title))
                .foregroundStyle(ColorTheme.typography.color)
                .offset(y: 1)
        }
        .frame(height: 44)
        // The wordmark is a logo, not a sentence: it grows with the font up to
        // xxxLarge, not up to AX3 - there it read "StorySh...".
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Akari"))
    }
}
