import Foundation
import Testing

@testable import BookReader

@Suite("Reading style")
@MainActor
struct ReadingStyleTests {

    private func persistence() -> UserDefaults {
        let name = "lesestil-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Defaults: publisher style on, automatic, 100 %")
    func presets() {
        let style = ReadingStyle(persistence: persistence())
        #expect(style.size == 1.0)
        #expect(style.theme == .automatic)
        #expect(style.publisherStyle)
        #expect(style.effectiveTheme(dark: true) == .dark)
        #expect(style.effectiveTheme(dark: false) == .light)
        let v = style.presets(dark: false)
        #expect(v.lineHeight == nil)
        #expect(v.textAlign == nil)
        #expect(v.publisherStyles == true)
        #expect(v.fontFamily == nil)
    }

    @Test("What is set is there again after reloading")
    func saved() {
        let d = persistence()
        let style = ReadingStyle(persistence: d)
        style.theme = .sepia
        style.size = 1.3
        style.typography = .charter
        style.publisherStyle = false
        style.justified = true
        let new = ReadingStyle(persistence: d)
        #expect(new.theme == .sepia)
        #expect(new.size == 1.3)
        #expect(new.typography == .charter)
        let v = new.presets(dark: true)
        #expect(v.textAlign == .justify)
        #expect(v.lineHeight == ReadingStyle.defaultLineSpacing)
        #expect(v.fontFamily?.rawValue == "Charter")
        #expect(v.theme == .sepia)
        new.reset()
        #expect(ReadingStyle(persistence: d).theme == .automatic)
    }

    @Test("Columns: narrow always Readium's choice; wide automatic = one in portrait, Readium in landscape")
    func columns() {
        let style = ReadingStyle(persistence: persistence())
        #expect(style.columns == .automatic)
        #expect(style.columnCount(wide: false, landscape: false) == nil, "iPhone as before")
        #expect(style.columnCount(wide: false, landscape: true) == nil)
        #expect(style.columnCount(wide: true, landscape: false) == .one)
        #expect(style.columnCount(wide: true, landscape: true) == nil, "quer zwei — Readiums auto")
        style.columns = .two
        #expect(style.columnCount(wide: true, landscape: false) == .two)
        #expect(style.columnCount(wide: false, landscape: false) == nil, "the choice only applies on iPad")
        style.columns = .one
        #expect(style.columnCount(wide: true, landscape: true) == .one)
        #expect(style.presets(dark: false, wide: true, landscape: true).columnCount == .one)
        #expect(style.presets(dark: false).columnCount == nil)
        style.reset()
        #expect(style.columns == .automatic)
    }

    @Test("A footnote loses its markup")
    func footnote() {
        let words = FootnoteSheet.words(
            "<aside id=\"fn1\"><p>Erster&nbsp;Satz.</p><p>Zweiter &amp; letzter.</p></aside>")
        #expect(words == "Erster Satz.\n\nZweiter & letzter.")
    }
}
