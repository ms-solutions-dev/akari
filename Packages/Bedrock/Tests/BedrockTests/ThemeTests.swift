import Foundation
import Testing

@testable import Bedrock

/// Color themes, and above all: **whether they can be read.**
///
/// These tests are the reason ``Theme`` lives in `Bedrock` and carries its colors
/// as numbers instead of `Color`. A theme can be recomputed without building a
/// UI. Exactly that was missing once: when the ground changed from brown to
/// black, the palest text slipped to 4.1, and nobody noticed, because too little
/// contrast on a screen looks like intent.
@Suite("Color themes")
struct ThemeTests {

    @Test("Every text color is readable on every surface", arguments: Theme.all)
    func textIsReadable(_ theme: Theme) {
        // 4.5 is the usual limit for ordinary text. It applies here to **all three**
        // text levels, even the palest: what is too pale to read is no longer a level
        // but a surface with hints on it.
        //
        // **And on all three surfaces, not only on the ground.** Exactly this gap
        // existed: the correction of textFaint was computed against the ground
        // (5.2:1 ✓), and on the raised surface, the capsule backgrounds, the same color
        // fell to 4.1:1, and the test did not see it because it knew only the one
        // pairing. Text stands on all three surfaces in this app; the rule must
        // therefore hold for every pairing.
        for (stepName, color) in [
            ("text", theme.text),
            ("textDim", theme.textDim),
            ("textFaint", theme.textFaint),
        ] {
            for (surfaceName, surface) in [
                ("ground", theme.ground),
                ("surface", theme.surface),
                ("surfaceRaised", theme.surfaceRaised),
            ] {
                let ratio = Theme.contrastRatio(color, surface)
                #expect(
                    ratio >= 4.5,
                    """
                    \(theme.id): \(stepName) kommt auf \(surfaceName) \
                    nur auf \(String(format: "%.1f", ratio)):1
                    """
                )
            }
        }
    }

    /// **The loud button: text on the brand.** "Midnight" stood at 4.25:1 here since
    /// the blue brand applies on both devices. The brand is also the focus glow of
    /// the television and must hold 3:1 on the ground.
    @Test("The text holds on the brand, the brand on the ground", arguments: Theme.all)
    func textHoldsOnBrand(_ theme: Theme) {
        let typography = Theme.contrastRatio(theme.text, theme.brand)
        #expect(typography >= 4.5, "\(theme.id): text on brand only \(typography)")
        #expect(Theme.contrastRatio(theme.brand, theme.ground) >= 3)
    }

    @Test("The theme's text also holds on the accent base surface", arguments: Theme.all)
    func textHoldsOnAccentBase(_ theme: Theme) {
        // The base level of the accent color carries exactly the surfaces that show
        // state: the active filter button, the running season, the focused offer, and
        // on it stands the theme's text. With a target brightness of 0.22 the cream of
        // the cinema theme reached only 3.3:1 there; it was noticed only on
        // recalculation, because too little contrast on a screen looks like intent.
        //
        // The normalization makes the brightness independent of hue, so one hue would
        // suffice. It is still tested all around and across the saturation, so the
        // promise hangs on the result and not on the normalization.
        let text = Theme.relativeLuminance(theme.text)

        for hue in stride(from: 0.0, to: 360, by: 30) {
            for saturation in [AccentPalette.minimumSaturation, theme.accent.saturation, 0.9] {
                let c = AccentPalette(hue: hue, saturation: saturation).components(.base)
                let accent = AccentPalette.relativeLuminance(c.red, c.green, c.blue)
                let ratio = (max(text, accent) + 0.05) / (min(text, accent) + 0.05)

                #expect(
                    ratio >= 4.5,
                    """
                    \(theme.id): Schrift auf Akzent (Farbton \(Int(hue)), \
                    Sättigung \(saturation)) kommt nur auf \
                    \(String(format: "%.1f", ratio)):1
                    """
                )
            }
        }
    }

    @Test("The main text stands out clearly, not just barely", arguments: Theme.all)
    func mainTextHasHeadroom(_ theme: Theme) {
        // Running text on a television stands three meters away and runs through video
        // compression. What barely suffices on a computer screen does not suffice there.
        #expect(Theme.contrastRatio(theme.text, theme.ground) >= 10)
    }

    @Test("Dark text on a light surface holds as well", arguments: Theme.all)
    func inkOnBrightHolds(_ theme: Theme) {
        // ``Theme/inkOnBright`` stands on the light surface of a focused button, and
        // that carries the color of ``Theme/text``. It is the only pairing in the app
        // where the text is the darker of the two, and therefore the one most likely
        // to be forgotten when recoloring a theme.
        #expect(Theme.contrastRatio(theme.inkOnBright, theme.text) >= 10)
    }

    @Test("The text levels remain distinguishable", arguments: Theme.all)
    func stepsAreDistinct(_ theme: Theme) {
        // Three levels that look the same are one level with two superfluous names, and
        // the structure they are meant to carry is lost.
        let text = Theme.relativeLuminance(theme.text)
        let dim = Theme.relativeLuminance(theme.textDim)
        let faint = Theme.relativeLuminance(theme.textFaint)

        #expect(text > dim)
        #expect(dim > faint)
    }

    @Test("The ground is really dark in every theme", arguments: Theme.all)
    func groundStaysDark(_ theme: Theme) {
        // A theme may change the colors, not the nature of the app. A light ground
        // would no longer be a color theme but a second design, and every surface
        // computed against a dark ground would be wrong.
        #expect(Theme.relativeLuminance(theme.ground) < 0.05)
    }

    @Test("Surfaces lie above the ground and below the text", arguments: Theme.all)
    func surfacesSitBetween(_ theme: Theme) {
        let ground = Theme.relativeLuminance(theme.ground)
        let surface = Theme.relativeLuminance(theme.surface)
        let raised = Theme.relativeLuminance(theme.surfaceRaised)

        #expect(surface > ground, "\(theme.id): the surface does not stand out from the ground")
        #expect(raised > surface, "\(theme.id): the raised surface does not stand out")
        #expect(raised < Theme.relativeLuminance(theme.textFaint))
    }

    /// **"Contrast" is neutral gray** on both devices, because the identifier is
    /// handed over between them. Every surface and every text has three equal
    /// components; a warm tint would be the earlier version again.
    @Test("Contrast is neutral gray")
    func contrastIsGray() {
        let t = Theme.contrast
        for value in [
            t.ground, t.surface, t.surfaceRaised, t.line, t.lineSoft, t.text, t.textDim, t.textFaint,
        ] {
            let r = (value >> 16) & 0xFF, g = (value >> 8) & 0xFF, b = value & 0xFF
            #expect(r == g && g == b, "\(String(value, radix: 16)) is not gray")
        }
    }

    /// **The quiet text in "Cinema" is the phone's.**
    @Test("Cinema carries the phone's quiet text")
    func cinemaQuietText() {
        #expect(Theme.cinema.textFaint == 0x9C8A7C)
    }

    // MARK: - Choosing and securing

    @Test("Identifiers are unique")
    func idsAreUnique() {
        #expect(Set(Theme.all.map(\.id)).count == Theme.all.count)
    }

    @Test("An unknown name leads back to Cinema")
    func unknownFallsBack() {
        // Not to the first best: what comes from storage may stem from an older
        // version in which a theme existed that no longer does today. The app must then
        // look as shipped and not by chance.
        #expect(Theme.named(nil) == .cinema)
        #expect(Theme.named("gibtesnicht") == .cinema)
        #expect(Theme.named("midnight") == .midnight)
    }

    @Test("The choice survives a restart")
    func choiceIsPersisted() {
        let store = InMemoryStore()
        #expect(Theme.load(from: store) == .cinema)

        Theme.midnight.save(to: store)
        #expect(Theme.load(from: store) == .midnight)
    }
}
