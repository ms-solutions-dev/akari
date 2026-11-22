import XCTest

/// What every screenshot test shares: start the app with launch hooks, wait,
/// attach an image.
///
/// The images are named like the entry in the screenshot catalog
/// (`NN-state`) - the calling script sorts them by it. The tests run
/// alphabetically, hence the methods carry the number in the name.
///
/// Environment from the script (passed through with the `TEST_RUNNER_` prefix):
/// - `SCREENSHOT_QUER=1` - iPad landscape; only the tests marked for landscape run.
/// - `SCREENSHOT_NUR=<pattern>` - only tests whose name contains the pattern.
@MainActor
class ScreenshotTestCase: XCTestCase {

    var app: XCUIApplication!

    /// Sets `AKARI_GLOSSAR` on the next start (see waitForGlossarySheet).
    var glossaryTerm: String?

    /// Landscape only runs an excerpt - the core screens and what looks different in landscape.
    var landscape: Bool { ProcessInfo.processInfo.environment["SCREENSHOT_QUER"] == "1" }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws {
        continueAfterFailure = true
        if let only = ProcessInfo.processInfo.environment["SCREENSHOT_NUR"], !only.isEmpty,
            !only.split(separator: ",").contains(where: { name.contains($0) })
        {
            throw XCTSkip("nicht verlangt")
        }
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    /// Portrait only - landscape brings nothing new for this state.
    func portraitOnly() throws {
        if landscape { throw XCTSkip("nur hochkant") }
    }

    /// iPad only (e.g. double spread in the comic reader).
    func padOnly() throws {
        if !isPad { throw XCTSkip("nur iPad") }
    }

    /// Starts the app.
    /// - Parameters:
    ///   - mocks: fixed sample data instead of the servers (`-attrappen`).
    ///   - environment: hooks without the `AKARI_` prefix, e.g. `["PROBE": "serie"]`.
    @discardableResult
    func launch(mocks: Bool = false, _ environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        // `-ohneLaterne`: no start intro - the photos and checks begin on the start page.
        // `SCREENSHOT_SPRACHE=en` starts the app in English (README, store); default German.
        let language = ProcessInfo.processInfo.environment["SCREENSHOT_SPRACHE"] ?? "de"
        let locale = language == "en" ? "en_US" : "de_DE"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-ohneLaterne"]
        if mocks { app.launchArguments.append("-attrappen") }
        for (name, value) in environment { app.launchEnvironment["AKARI_\(name)"] = value }
        if let glossaryTerm { app.launchEnvironment["AKARI_GLOSSAR"] = glossaryTerm }
        app.launch()
        self.app = app
        // The tab bar is the sign that the shell stands.
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 15)
        return app
    }

    /// Attaches an image of the whole screen, after a settling time for images and
    /// transitions.
    func snap(_ name: String, pause seconds: Double = 2.5) {
        wait(seconds)
        let anhang = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        anhang.name = name
        anhang.lifetime = .keepAlways
        add(anhang)
    }

    /// The accessibility tree as a text attachment - for working on the tests, not for design.
    func tree(_ name: String) {
        let anhang = XCTAttachment(string: app.debugDescription)
        anhang.name = "baum-\(name)"
        anhang.lifetime = .keepAlways
        add(anhang)
    }

    func wait(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.1))) }
    }

    /// Taps the first element with this label when it appears.
    @discardableResult
    func tap(_ element: XCUIElement, pause: Double = 8) -> Bool {
        guard element.waitForExistence(timeout: pause) else { return false }
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    /// Opens via search the hit whose label begins with `title` + comma
    /// (the row is called "Title, secondary line") - scrolls until it is tappable. Real data
    /// shifts; the title stays.
    func openHit(search text: String, title: String) {
        launch(["BEREICH": "suche", "SUCHE": text])
        wait(3)
        let hit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + ",")).firstMatch
        for _ in 0..<8 where !(hit.exists && hit.isHittable) {
            app.swipeUp()
            wait(0.5)
        }
        tap(hit)
    }

    /// Waits for the glossary sheet that `AKARI_GLOSSAR` opens ten seconds after
    /// loading. An XCUITest tap on the underlined term does not arrive in the reader
    /// as a term tap (tried on measured spots and a grid);
    /// by hand it works.
    @discardableResult
    func waitForGlossarySheet() -> Bool {
        app.descendants(matching: .any)["Im Buch suchen"].waitForExistence(timeout: 15)
            || app.staticTexts["Glossar"].waitForExistence(timeout: 2)
    }

    /// Pages `pages` pages forward in the book reader (right edge).
    func turnForward(_ pages: Int) {
        for _ in 0..<pages {
            tapSpot(0.92, 0.5)
            wait(1)
        }
    }

    /// Cleans up after paging in the real book: back by the same amount, wait until the
    /// state is written, and close the reader properly. Otherwise every run pushes
    /// the real reading state on the server further.
    func turnBackAndClose(_ pages: Int) {
        app.swipeDown()  // close an open sheet
        wait(1)
        for _ in 0..<pages {
            tapSpot(0.08, 0.5)
            wait(1.2)
        }
        wait(12)
        tapSpot(0.5, 0.5)
        wait(1.5)
        tapSpot(0.07, 0.085)
        wait(5)
    }

    /// A tab of the bar (Start, Library, Search).
    func reiter(_ name: String) {
        tap(app.tabBars.buttons[name])
    }

    /// Taps a spot on the screen (fractions 0 to 1).
    func tapSpot(_ x: Double, _ y: Double) {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
}
