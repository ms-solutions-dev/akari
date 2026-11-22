import XCTest

/// Book, comic and audiobook readers - with the real servers. The book is "Der
/// Twenty Thousand Leagues", because it carries the glossary at the back.
final class C_Reading: ScreenshotTestCase {

    /// Opens the book via search -> detail -> continue reading and waits until
    /// Readium has drawn the page.
    private func openBook(glossary: String? = nil) {
        if let glossary { glossaryTerm = glossary }
        openHit(search: "leagues", title: "Twenty Thousand Leagues Under the Seas")
        tap(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Weiterlesen' OR label == 'Lesen'")
            ).firstMatch)
        _ = app.webViews.firstMatch.waitForExistence(timeout: 20)
        wait(4)
    }

    /// Shows the book reader's control bars (tap in the middle).
    private func showBars() {
        tapSpot(0.5, 0.5)
        wait(1.2)
    }

    func test_28_bookreader_text() throws {
        openBook()
        snap("28-buchleser-text", pause: 1)
    }

    func test_29_bookreader_bar() throws {
        openBook()
        showBars()
        snap("29-buchleser-leiste", pause: 0.5)
    }

    func test_30_bookreader_glossary_marked() throws {
        openBook()
        // Page 8 is the chapter head - three pages further (Nautilus, Captain Nemo,
        // Aronnax) the terms are dense.
        turnForward(3)
        snap("30-buchleser-glossar-markiert", pause: 1.5)
        turnBackAndClose(3)
    }

    func test_31_bookreader_glossary_sheet() throws {
        openBook(glossary: "Nautilus")
        turnForward(3)
        if waitForGlossarySheet() { snap("31-buchleser-glossarblatt", pause: 1.5) }
        turnBackAndClose(3)
    }

    func test_32_bookreader_appearance() throws {
        openBook()
        showBars()
        tap(app.buttons["Schrift und Darstellung"].firstMatch)
        snap("32-buchleser-darstellung", pause: 2)
    }

    func test_33_bookreader_contents() throws {
        try portraitOnly()
        openBook()
        showBars()
        tap(app.buttons["Inhalt"].firstMatch)
        snap("33-buchleser-inhalt", pause: 2)
    }

    func test_34_bookreader_sepia() throws {
        try portraitOnly()
        openBook()
        showBars()
        tap(app.buttons["Schrift und Darstellung"].firstMatch)
        wait(1)
        tap(app.buttons["Sepia"].firstMatch)
        // Close the sheet so the page is free.
        tapSpot(0.5, 0.15)
        wait(1)
        tapSpot(0.5, 0.15)
        snap("34-buchleser-sepia", pause: 2)
        // Back to Automatic, otherwise Sepia stays on for the next shots.
        showBars()
        tap(app.buttons["Schrift und Darstellung"].firstMatch)
        tap(app.buttons["Automatisch"].firstMatch)
    }

    // MARK: Comic

    func test_35_comicreader_page() throws {
        launch(["PROBE": "lesen"])
        wait(8)
        snap("35-comicleser-seite", pause: 1)
    }

    func test_36_comicreader_bar() throws {
        launch(["PROBE": "lesen"])
        wait(8)
        tapSpot(0.5, 0.5)
        snap("36-comicleser-leiste", pause: 1)
    }

    // MARK: Audiobook

    func test_37_audiobook_player() throws {
        launch(["PROBE": "hoerbuch"])
        snap("37-hoerbuch-spieler", pause: 5)
    }

    func test_38_audiobook_miniplayer() throws {
        launch(["PROBE": "mini"])
        snap("38-hoerbuch-minispieler", pause: 7)
    }
}
