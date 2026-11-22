import XCTest

/// Start, library, search, detail pages - with the real servers.
final class B_Browse: ScreenshotTestCase {

    func test_05_start() throws {
        launch()
        snap("05-start", pause: 4)
    }

    func test_06_start_bottom() throws {
        try portraitOnly()
        launch()
        wait(3)
        app.swipeUp()
        app.swipeUp()
        snap("06-start-unten")
    }

    // MARK: Library

    /// Sets the view via the menu at the top right (Titles - Series - Shelves - Authors).
    private func hostView(_ name: String) {
        let menu = app.buttons["Sortieren und filtern"].firstMatch
        if !menu.waitForExistence(timeout: 5) {
            // Without a grid the menu sits in the header of the view (Shelves, Authors).
            tap(app.buttons["Ansicht"].firstMatch)
        } else {
            menu.tap()
        }
        tap(app.buttons[name].firstMatch, pause: 4)
    }

    private func library(_ segment: String, _ viewName: String?) {
        launch(["BEREICH": "bibliothek"])
        if let viewName { hostView(viewName) }
        tap(app.buttons[segment].firstMatch)
    }

    func test_07_library_all() throws {
        library("Alle", "Titel")
        snap("07-bibliothek-alle", pause: 4)
    }

    func test_08_library_manga_grid() throws {
        library("Manga", "Titel")
        snap("08-bibliothek-manga-raster", pause: 4)
    }

    func test_09_library_manga_rows() throws {
        try portraitOnly()
        library("Manga", "Reihen")
        // Series and titles only differ in the grid under Genres and Shelves.
        wait(3)
        app.swipeUp()
        snap("09-bibliothek-manga-reihen")
    }

    func test_10_library_books_grid() throws {
        library("Bücher", "Titel")
        snap("10-bibliothek-buecher-raster", pause: 4)
    }

    func test_11_library_books_rows() throws {
        try portraitOnly()
        library("Bücher", "Reihen")
        // Series and titles only differ in the grid under Genres and Shelves.
        wait(3)
        app.swipeUp()
        snap("11-bibliothek-buecher-reihen")
    }

    func test_12_library_audiobooks() throws {
        library("Hörbücher", "Titel")
        snap("12-bibliothek-hoerbuecher", pause: 4)
    }

    func test_13_library_podcasts() throws {
        try portraitOnly()
        library("Podcasts", "Titel")
        snap("13-bibliothek-podcasts", pause: 4)
    }

    func test_14_library_shelves() throws {
        library("Bücher", "Regale")
        snap("14-bibliothek-regale", pause: 4)
    }

    func test_15_library_authors_list() throws {
        try portraitOnly()
        library("Bücher", "Autoren")
        snap("15-bibliothek-autoren-liste", pause: 4)
    }

    func test_16_library_genre() throws {
        try portraitOnly()
        library("Alle", "Titel")
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fantasy'")).firstMatch)
        snap("16-bibliothek-genre", pause: 4)
    }

    func test_17_filter_sheet() throws {
        try portraitOnly()
        launch(["BEREICH": "bibliothek", "PROBE": "filter"])
        snap("17-filterblatt", pause: 3)
    }

    func test_18_filter_active() throws {
        try portraitOnly()
        launch(["BEREICH": "bibliothek", "PROBE": "filterchips"])
        tap(app.buttons["Bücher"].firstMatch)
        snap("18-filter-aktiv", pause: 3)
    }

    // MARK: Search

    func test_19_search_empty() throws {
        try portraitOnly()
        launch(["BEREICH": "suche"])
        snap("19-suche-leer")
    }

    func test_20_search_hits() throws {
        launch(["BEREICH": "suche", "SUCHE": "holmes"])
        snap("20-suche-treffer", pause: 3)
    }

    // MARK: Detail pages

    func test_21_detail_series_manga() throws {
        launch(["PROBE": "serie"])
        snap("21-detail-serie-manga", pause: 4)
    }

    func test_22_detail_series_gaps() throws {
        try portraitOnly()
        launch(["PROBE": "reihenluecken"])
        snap("22-detail-serie-luecken", pause: 4)
    }

    func test_23_detail_book() throws {
        openHit(search: "leagues", title: "Twenty Thousand Leagues Under the Seas")
        snap("23-detail-buch", pause: 4)
    }

    func test_24_detail_book_bottom() throws {
        try portraitOnly()
        openHit(search: "leagues", title: "Twenty Thousand Leagues Under the Seas")
        wait(3)
        app.swipeUp()
        snap("24-detail-buch-unten")
    }

    func test_25_detail_audiobook() throws {
        openHit(search: "digorem", title: "Digorem")
        snap("25-detail-hoerbuch", pause: 4)
    }

    func test_26_author() throws {
        try portraitOnly()
        launch(["PROBE": "autor"])
        snap("26-autor", pause: 5)
    }

    func test_27_saved() throws {
        try portraitOnly()
        launch(["PROBE": "gemerkt"])
        snap("27-gemerkt", pause: 4)
    }
}
