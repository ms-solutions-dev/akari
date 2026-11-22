import Foundation

/// A color theme: all surface, text and signal colors of the app in one place.
///
/// **Why a value and not fixed colors in the design system.** Until here the
/// colors stood as constants in ``Tokens/Palette``. That was right as long as
/// there was one design; once there are to be several, every constant is a place
/// that can be forgotten when switching. Here every color stands exactly once,
/// and a new theme is a table, with no intervention at 397 call sites.
///
/// **Colors as numbers and not as `Color`.** This type lives in the foundation
/// package, which does not know SwiftUI. That is no accident: it lets a theme be
/// checked without building a UI, for instance whether its text has enough
/// contrast on its ground. Exactly this computation was missing when the ground
/// changed from brown to black and `textFaint` slipped below the recommendation
/// without anybody noticing.
public struct Theme: Sendable, Equatable, Identifiable {

    public let id: String
    /// Localization key of the name.
    public let nameKey: String

    // MARK: - Surfaces

    /// Base surface of all views, **and** the text color on light surfaces.
    public let ground: UInt32
    /// Dark text on a light surface, where it may carry a hint of color.
    public let inkOnBright: UInt32
    public let surface: UInt32
    public let surfaceRaised: UInt32
    public let line: UInt32
    public let lineSoft: UInt32

    // MARK: - Text

    public let text: UInt32
    public let textDim: UInt32
    public let textFaint: UInt32

    // MARK: - Brand and signals

    public let brand: UInt32
    public let brandBright: UInt32
    public let brandDeep: UInt32

    /// Deliberately kept apart from the series color: progress must not blur into
    /// the accent, otherwise it cannot be read on colored cards.
    public let progress: UInt32
    public let live: UInt32
    public let success: UInt32

    /// The fallback color while no series color is known.
    ///
    /// It belongs in the theme, and that is no small thing: it carries the focus, the
    /// brand symbol and every highlight before the color has been derived from the
    /// image. If it stayed fixed, a cool theme would have a red focus, and that does
    /// not look like a different design but like a mistake.
    public let accent: AccentPalette

    public init(
        id: String,
        nameKey: String,
        ground: UInt32,
        inkOnBright: UInt32,
        surface: UInt32,
        surfaceRaised: UInt32,
        line: UInt32,
        lineSoft: UInt32,
        text: UInt32,
        textDim: UInt32,
        textFaint: UInt32,
        brand: UInt32,
        brandBright: UInt32,
        brandDeep: UInt32,
        progress: UInt32,
        live: UInt32,
        success: UInt32,
        accent: AccentPalette
    ) {
        self.id = id
        self.nameKey = nameKey
        self.ground = ground
        self.inkOnBright = inkOnBright
        self.surface = surface
        self.surfaceRaised = surfaceRaised
        self.line = line
        self.lineSoft = lineSoft
        self.text = text
        self.textDim = textDim
        self.textFaint = textFaint
        self.brand = brand
        self.brandBright = brandBright
        self.brandDeep = brandDeep
        self.progress = progress
        self.live = live
        self.success = success
        self.accent = accent
    }

    // MARK: - The themes

    /// The design the app was built with: warm popcorn cream on a black ground, the
    /// red of the armchair from the logo.
    ///
    /// The ground is true black and the warmth lies **on top**. It was once the other
    /// way round, with a red-tinted ground, and across a large empty area on a
    /// 55-inch device that turned into a dull gray veil: the screen showed *almost*
    /// black, and that looks like a badly adjusted television rather than intent.
    public static let cinema = Theme(
        id: "cinema",
        nameKey: "theme.cinema",
        ground: 0x000000,
        inkOnBright: 0x0A0504,
        surface: 0x1C110F,
        surfaceRaised: 0x2A1A16,
        line: 0x3A241F,
        lineSoft: 0x241512,
        text: 0xF7EBD6,
        textDim: 0xB4A093,
        // Raised three times, the first two by recalculation: 0x7B6A60 reached only 4.1:1
        // against the black ground; the correction to 0x8E7B70 was computed only against
        // the ground and fell back to 4.1:1 on the raised surface, the capsule
        // backgrounds. After that 0x958374 (4.59 on the raised surface). **Now
        // 0x9C8A7C, the value of the phone**: 5.04:1 on the raised surface instead of
        // 4.59. The headroom above the limit counts for more from three meters than in
        // the hand, and both devices show the same theme.
        textFaint: 0x9C8A7C,
        brand: 0xC4302B,
        brandBright: 0xE2564A,
        brandDeep: 0x6B1710,
        progress: 0xE8B54A,
        live: 0xE05B4C,
        success: 0x6FA86A,
        accent: AccentPalette(hue: 2, saturation: 0.64)
    )

    /// Cool and neutral: no warmth in the surfaces, a blue accent.
    ///
    /// For whoever finds the warm one too much, and for bright rooms where the red
    /// tint of the surfaces is read as a color cast of the television.
    public static let midnight = Theme(
        id: "midnight",
        nameKey: "theme.midnight",
        ground: 0x000000,
        inkOnBright: 0x05070A,
        surface: 0x11161C,
        surfaceRaised: 0x1B2129,
        line: 0x2A323C,
        lineSoft: 0x171D24,
        text: 0xEAF0F6,
        textDim: 0xA6B2BF,
        // Slightly lighter than 0x7C8896: the old value held only 4.49:1 on the raised
        // surface, just below the limit, and just missing is still missing.
        textFaint: 0x808C9A,
        // **Slightly darker than 0x2F6FD0:** on the old brand the text of the loud
        // button stood at 4.25:1. With 0x2D6ACA it is 4.54:1; as a focus glow the brand
        // still holds 4.0:1 on the ground.
        brand: 0x2D6ACA,
        brandBright: 0x5C97EE,
        brandDeep: 0x123258,
        // **The three meaning colors are the same as in "Cinema", and the same as on the
        // phone.**
        //
        // **Counted, the finding was: 0 of 14 shared values.** Two apps side by side,
        // and not a single color value matched. The most conspicuous was `progress`:
        // gold here, **turquoise** there, and the progress bar is often the only
        // colored element in the picture from three meters.
        //
        // **Only these three are aligned, and explicitly not `brand`.** The brand
        // colors here are also the **ring color** of the focus
        // (``Tokens/Palette/brand``); aligning them would mean a red focus ring in the
        // cool theme, which ``AccentPalette`` explicitly warns about. So 0/14 becomes
        // 3/14 and not 6/14.
        //
        // **And the phone does it the same way:** there "Cinema" and "Midnight" carry
        // the same `gold`/`live`/`good`; they differ only in "Contrast", and there for
        // one reason (see below).
        progress: 0xE8B54A,
        live: 0xE05B4C,
        success: 0x6FA86A,
        accent: AccentPalette(hue: 214, saturation: 0.62)
    )

    /// For distance and poor eyesight: more contrast, stronger signals.
    ///
    /// **Not a look of its own but the same, louder,** and **neutral gray and
    /// identical on both devices.** Until then the surfaces here were warmly tinted
    /// (`0x201512` …) and gray on the phone, with the same identifier `contrast`
    /// that is handed over between the devices. The owner chose the phone's version.
    /// The brand is the same as there (`0xC4302B`); as the television's focus glow it
    /// holds 3.8:1 on the ground and thus the threshold for controls.
    public static let contrast = Theme(
        id: "contrast",
        nameKey: "theme.contrast",
        ground: 0x000000,
        inkOnBright: 0x000000,
        surface: 0x141414,
        surfaceRaised: 0x232323,
        line: 0x3D3D3D,
        lineSoft: 0x1C1C1C,
        text: 0xFFFFFF,
        textDim: 0xD6D6D6,
        textFaint: 0xB4B4B4,
        brand: 0xC4302B,
        brandBright: 0xE2564A,
        brandDeep: 0x6B1710,
        // **The phone's values here too, but those of its contrast theme.** Pulling them
        // to "Cinema" would be the mistake this theme must not make: it is lighter
        // **because** it is meant to be lighter. The color is aligned, not the purpose.
        progress: 0xFFC85C,
        live: 0xFF7A6B,
        success: 0x7ED97A,
        accent: AccentPalette(hue: 2, saturation: 0.70)
    )

    /// All themes in the order in which they are offered.
    public static let all: [Theme] = [.cinema, .midnight, .contrast]

    public static func named(_ id: String?) -> Theme {
        all.first { $0.id == id } ?? .cinema
    }

    // MARK: - The theme currently in effect

    /// **Why a mutable global, and why that is defensible here.**
    ///
    /// The alternative would be to pass the theme through the environment: cleaner,
    /// but 397 call sites away. The rework would bring the same effect with
    /// incomparably more opportunity for errors, in places nobody checks any more.
    ///
    /// It is read exclusively while building views, so on the main thread. It is
    /// written in exactly one place: ``ThemeStore``, also there. Hence
    /// `nonisolated(unsafe)`: the assurance is not "doesn't matter" but "touched
    /// from one thread only".
    ///
    /// **And the catch you need to know:** SwiftUI notices none of this by itself.
    /// Whoever changes this value must have the tree rebuilt; ``ThemeStore`` does
    /// that via an identifier at the root.
    public nonisolated(unsafe) static var current: Theme = .cinema

    // MARK: - Contrast

    /// The contrast ratio of two colors, 1 to 21.
    ///
    /// By the usual computation: relative luminance of both colors, lighter plus
    /// 0.05 divided by darker plus 0.05. From 4.5 on, ordinary text counts as
    /// readable.
    ///
    /// **It lives here because it is needed here and not only in a test.** When the
    /// ground changed from brown to black, `textFaint` slipped to 4.1, and nobody
    /// noticed, because too little contrast on a screen looks like intent. A number
    /// notices; a glance does not.
    ///
    /// **This is THE one version for both programs.** On the phone a copy of the same
    /// formula exists, and this package is already linked there as a path dependency,
    /// so the copy is not even necessary.
    ///
    /// **Two versions of a threshold computation are noticed only when one is
    /// corrected,** and by then one of the two apps has colored by the wrong
    /// threshold for months without anything turning red. Whoever touches the formula
    /// touches it **here**; the phone version is the copy and is to be replaced by a
    /// call.
    public static func contrastRatio(_ first: UInt32, _ second: UInt32) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The relative luminance of a color, 0 to 1.
    ///
    /// The components are linearized first: a screen does not output them linearly,
    /// and whoever skips that takes mid gray for half as bright as white. It is
    /// barely a fifth.
    public static func relativeLuminance(_ hex: UInt32) -> Double {
        func fraction(_ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) / 255 }
        return AccentPalette.relativeLuminance(fraction(16), fraction(8), fraction(0))
    }

    // MARK: - Securing

    static let storageKey = "appearance.theme"

    public static func load(from store: any KeyValueStore) -> Theme {
        named(try? store.value(for: storageKey))
    }

    public func save(to store: any KeyValueStore) {
        try? store.set(id, for: Self.storageKey)
    }
}
