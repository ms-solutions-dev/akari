import Testing

@testable import Bedrock

/// The color derivation has proven deceptive twice, so the property that matters
/// is proven: all series colors must look **equally vivid**. Without
/// normalization to perceived brightness, a yellow-green shines many times
/// brighter than a red with the same computed value.
@Suite("Accent colors")
struct AccentPaletteTests {

    /// The hues determined from the library's artwork.
    static let crimson = AccentPalette(hue: 349, saturation: 0.6)
    static let indigo = AccentPalette(hue: 229, saturation: 0.9)
    static let amber = AccentPalette(hue: 19, saturation: 0.78)

    @Test(
        "Jeder Farbton trifft die vorgegebene wahrgenommene Helligkeit",
        arguments: [
            AccentPalette(hue: 349, saturation: 0.6),
            AccentPalette(hue: 229, saturation: 0.9),
            AccentPalette(hue: 19, saturation: 0.78),
            AccentPalette(hue: 70, saturation: 0.7),  // yellow-green, the difficult case
        ]
    )
    func hitsTargetLuminance(palette: AccentPalette) {
        for level in AccentPalette.Level.allCases {
            let c = palette.components(level)
            let luminance = AccentPalette.relativeLuminance(c.red, c.green, c.blue)

            #expect(
                abs(luminance - level.rawValue) < 0.01,
                "Farbton \(palette.hue) verfehlt bei \(level) die Zielhelligkeit"
            )
        }
    }

    @Test("The three series colors look equally vivid")
    func equalStrength() {
        let luminances = [Self.crimson, Self.indigo, Self.amber].map { palette -> Double in
            let c = palette.components(.base)
            return AccentPalette.relativeLuminance(c.red, c.green, c.blue)
        }

        let spread = luminances.max()! - luminances.min()!
        #expect(spread < 0.01, "The accents must not differ in effect")
    }

    @Test("Yellow-green does not look brighter than red")
    func greenIsNotBrighter() {
        // Exactly this case went wrong on the first attempt: a yellow-green with the
        // same computed brightness value shone far brighter.
        let green = AccentPalette(hue: 70, saturation: 0.7).components(.base)
        let red = AccentPalette(hue: 0, saturation: 0.7).components(.base)

        let lg = AccentPalette.relativeLuminance(green.red, green.green, green.blue)
        let lr = AccentPalette.relativeLuminance(red.red, red.green, red.blue)

        #expect(abs(lg - lr) < 0.01)
    }

    @Test("The levels get brighter from dark to light")
    func levelsAscend() {
        let p = Self.amber
        func lum(_ level: AccentPalette.Level) -> Double {
            let c = p.components(level)
            return AccentPalette.relativeLuminance(c.red, c.green, c.blue)
        }

        #expect(lum(.deep) < lum(.base))
        #expect(lum(.base) < lum(.bright))
    }

    @Test("Hex values have the expected format")
    func hexFormat() {
        let hex = Self.amber.hex(.base)

        #expect(hex.hasPrefix("#"))
        #expect(hex.count == 7)
    }

    @Test("Hue is limited to the circle, saturation to zero through one")
    func clamping() {
        #expect(AccentPalette(hue: 380, saturation: 0.5).hue == 20)
        #expect(AccentPalette(hue: 100, saturation: 1.7).saturation == 1)
        #expect(AccentPalette(hue: 100, saturation: -0.4).saturation == 0)
    }

    @Test("The brand color is the red from the logo")
    func brandIsRed() {
        // Red lies at the start of the color wheel; anything above 30 degrees would be orange.
        #expect(AccentPalette.brand.hue < 30 || AccentPalette.brand.hue > 330)
    }
}
