import Foundation
import Observation
import ReadiumNavigator
import SwiftUI

/// The "Aa" sheet as a value: size, line spacing, margins, justification, reading theme,
/// typeface, publisher style, hyphenation, flow and animation - independent of the
/// app's theme. Stored in UserDefaults under
/// `buch.stil.*`, the same for all books: whoever wants sepia once, always wants it.
///
/// **What Readium CSS allows:** line spacing, justification and hyphenation
/// only apply when the publisher style is off - hence the sheet switches it off
/// as soon as one of these controls is moved, like Apple Books.
@MainActor
@Observable
public final class ReadingStyle {

    public enum ReadingTheme: String, CaseIterable, Sendable, Identifiable {
        /// `night`: true black for OLED in the dark.
        case light = "hell", sepia, dark = "dunkel", night = "nacht", automatic = "automatisch"
        public var id: String { rawValue }
    }

    /// The typefaces: the publisher's (what the book brings along) and six system fonts
    /// every iPhone has - no font files in the bundle.
    public enum TypographyChoice: String, CaseIterable, Sendable, Identifiable {
        case publisher = "verlag", georgia, palatino, charter, iowan, avenir, helvetica
        public var id: String { rawValue }

        /// The CSS family name; `nil` keeps the book's typeface.
        public var family: String? {
            switch self {
            case .publisher: nil
            case .georgia: "Georgia"
            case .palatino: "Palatino"
            case .charter: "Charter"
            case .iowan: "Iowan Old Style"
            case .avenir: "Avenir Next"
            case .helvetica: "Helvetica Neue"
            }
        }

        /// The name on the sheet - typeface names are not translated.
        public var name: String {
            switch self {
            case .publisher: String(localized: "book.typeface.publisher", bundle: .main)
            case .georgia: "Georgia"
            case .palatino: "Palatino"
            case .charter: "Charter"
            case .iowan: "Iowan"
            case .avenir: "Avenir"
            case .helvetica: "Helvetica"
            }
        }
    }

    /// The columns on iPad: "Automatic" is one in portrait, two in landscape - like Books;
    /// Readium's own `auto` gave two columns of 55 characters in portrait, 35 at 130 %
    /// font size. One in portrait, two in landscape, and a switch, because pinching changes
    /// the font size and the column count then co-decides. In the narrow size class
    /// (iPhone, split view) Readium's `auto` still applies, whatever is set here.
    public enum ColumnChoice: String, CaseIterable, Sendable, Identifiable {
        case automatic = "automatisch", one = "eine", two = "zwei"
        public var id: String { rawValue }
    }

    public var size: Double { didSet { secure("groesse", size) } }
    public var lineSpacing: Double { didSet { secure("zeilenabstand", lineSpacing) } }
    public var margins: Double { didSet { secure("raender", margins) } }
    public var justified: Bool { didSet { secure("blocksatz", justified) } }
    public var theme: ReadingTheme { didSet { secure("thema", theme.rawValue) } }
    public var typography: TypographyChoice { didSet { secure("schrift", typography.rawValue) } }
    public var publisherStyle: Bool { didSet { secure("verlagsstil", publisherStyle) } }
    public var hyphenation: Bool { didSet { secure("silbentrennung", hyphenation) } }
    /// Scroll fluidly instead of paging.
    public var reflowing: Bool { didSet { secure("fliessend", reflowing) } }
    /// Paging with sliding - off means: the page appears immediately.
    public var animation: Bool { didSet { secure("animation", animation) } }
    /// Both edges page forward - going back is then only possible by swiping.
    public var bothMarginsForward: Bool { didSet { secure("beideRaenderVor", bothMarginsForward) } }
    /// Underline terms from the book's glossary in the text - only where there
    /// is one; a tap shows the explanation.
    public var glossary: Bool { didSet { secure("glossar", glossary) } }
    /// Explanations in the term sheet hidden, a tap reveals - spoiler protection for glossaries
    /// at the end of the book.
    public var explanationAfterTap: Bool { didSet { secure("erklaerungNachTipp", explanationAfterTap) } }
    /// Marking "Prominent" instead of "Sparse": accent color at 70 %, 0.08 em.
    public var pronounced: Bool { didSet { secure("deutlich", pronounced) } }
    /// "Tapping opens explanation" - independent of marking. Off: only "In the book".
    public var tap: Bool { didSet { secure("antippen", tap) } }
    /// "Always page at the edge": a tap in the edge quarter pages, even on a term.
    public var edgeTurning: Bool { didSet { secure("randBlaettern", edgeTurning) } }
    public var columns: ColumnChoice { didSet { secure("spalten", columns.rawValue) } }

    public static let sizeRange: ClosedRange<Double> = 0.7...2.2
    public static let lineSpacingRange: ClosedRange<Double> = 1.0...2.0
    public static let marginRange: ClosedRange<Double> = 0.5...2.5
    public static let defaultLineSpacing = 1.5
    public static let defaultMargins = 1.3

    private let persistence: UserDefaults
    private static let prefix = "buch.stil."

    public init(persistence: UserDefaults = .standard) {
        self.persistence = persistence
        let integer = { (name: String, preset: Double) -> Double in
            persistence.object(forKey: ReadingStyle.prefix + name) as? Double ?? preset
        }
        let truth = { (name: String, preset: Bool) -> Bool in
            persistence.object(forKey: ReadingStyle.prefix + name) as? Bool ?? preset
        }
        size = integer("groesse", 1.0)
        // Line height 1.5 and slightly more margin (about 24 pt instead of 18).
        lineSpacing = integer("zeilenabstand", ReadingStyle.defaultLineSpacing)
        margins = integer("raender", ReadingStyle.defaultMargins)
        justified = truth("blocksatz", false)
        theme =
            ReadingTheme(rawValue: persistence.string(forKey: ReadingStyle.prefix + "thema") ?? "")
            ?? .automatic
        typography =
            TypographyChoice(rawValue: persistence.string(forKey: ReadingStyle.prefix + "schrift") ?? "")
            ?? .publisher
        publisherStyle = truth("verlagsstil", true)
        hyphenation = truth("silbentrennung", true)
        reflowing = truth("fliessend", false)
        animation = truth("animation", true)
        bothMarginsForward = truth("beideRaenderVor", false)
        glossary = truth("glossar", true)
        explanationAfterTap = truth("erklaerungNachTipp", false)
        pronounced = truth("deutlich", false)
        tap = truth("antippen", true)
        edgeTurning = truth("randBlaettern", false)
        columns =
            ColumnChoice(rawValue: persistence.string(forKey: ReadingStyle.prefix + "spalten") ?? "")
            ?? .automatic
    }

    /// Reset everything - the button at the bottom of the sheet.
    public func reset() {
        size = 1.0
        lineSpacing = ReadingStyle.defaultLineSpacing
        margins = ReadingStyle.defaultMargins
        justified = false
        theme = .automatic
        typography = .publisher
        publisherStyle = true
        hyphenation = true
        reflowing = false
        animation = true
        bothMarginsForward = false
        glossary = true
        explanationAfterTap = false
        pronounced = false
        tap = true
        edgeTurning = false
        columns = .automatic
    }

    /// The theme that currently applies - "Automatic" follows the system.
    public func effectiveTheme(dark: Bool) -> ReadingTheme {
        theme == .automatic ? (dark ? .dark : .light) : theme
    }

    private func secure(_ name: String, _ value: Any) {
        persistence.set(value, forKey: ReadingStyle.prefix + name)
    }
}

// MARK: - Colors and Readium

extension ReadingStyle.ReadingTheme {

    /// Paper and ink per theme - sepia is `#F3EBDD`.
    var paper: UInt32 {
        switch self {
        case .light, .automatic: 0xFDFC_F8
        case .sepia: 0xF3EB_DD
        case .dark: 0x1412_10
        case .night: 0x0000_00
        }
    }

    var ink: UInt32 {
        switch self {
        case .light, .automatic: 0x1B1A_17
        case .sepia: 0x4A3B_2C
        case .dark: 0xE6E2_DA
        case .night: 0xBDB6_AA
        }
    }

    /// Opacity of the term line in percent of the text color: stronger on dark paper
    /// so it looks equally restrained.
    var hairline: Int {
        switch self {
        case .light, .automatic: 30
        case .sepia: 32
        case .dark: 38
        case .night: 42
        }
    }

    var paperColor: SwiftUI.Color { SwiftUI.Color(hex: paper) }
    var inkColor: SwiftUI.Color { SwiftUI.Color(hex: ink) }
    var isDark: Bool { self == .dark || self == .night }
}

extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

extension ReadingStyle {

    /// The column count for Readium - `nil` is Readium's own choice (`auto`): always so in
    /// the narrow size class, and on iPad in landscape, where "Automatic" wants two.
    public func columnCount(wide: Bool, landscape: Bool) -> ColumnCount? {
        guard wide else { return nil }
        switch columns {
        case .one: return .one
        case .two: return .two
        case .automatic: return landscape ? nil : .one
        }
    }

    /// The settings as Readium preferences. Right-to-left and the language
    /// come from the book, not from here; size class and orientation from the window.
    func presets(dark: Bool, wide: Bool = false, landscape: Bool = false) -> EPUBPreferences {
        let theme = effectiveTheme(dark: dark)
        return EPUBPreferences(
            backgroundColor: ReadiumNavigator.Color(rawValue: Int(theme.paper)),
            columnCount: columnCount(wide: wide, landscape: landscape),
            fontFamily: typography.family.map { FontFamily(rawValue: $0) },
            fontSize: size,
            hyphens: publisherStyle ? nil : hyphenation,
            lineHeight: publisherStyle ? nil : lineSpacing,
            pageMargins: margins,
            publisherStyles: publisherStyle,
            scroll: reflowing,
            textAlign: publisherStyle ? nil : (justified ? .justify : .start),
            textColor: ReadiumNavigator.Color(rawValue: Int(theme.ink)),
            theme: theme.isDark ? .dark : (theme == .sepia ? .sepia : .light)
        )
    }

    /// The settings for a PDF - there are only flow and background.
    func pdfPreferences(dark: Bool) -> PDFPreferences {
        let theme = effectiveTheme(dark: dark)
        return PDFPreferences(
            backgroundColor: ReadiumNavigator.Color(rawValue: Int(theme.paper)),
            scroll: reflowing,
            scrollAxis: .vertical
        )
    }
}
