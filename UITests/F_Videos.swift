import XCTest

/// Short transitions as video. The test does not film itself - it writes "start" and
/// "stop" into the marker file (`SCREENSHOT_MARKE`), and the calling script starts
/// and ends `simctl io recordVideo` accordingly. Without a marker file the tests do not run.
final class F_Videos: ScreenshotTestCase {

    private var marker: String? { ProcessInfo.processInfo.environment["SCREENSHOT_MARKE"] }

    override func setUp() async throws {
        try await super.setUp()
        if marker == nil { throw XCTSkip("nur mit Markendatei") }
    }

    private func set(_ word: String) {
        guard let marker else { return }
        try? word.write(toFile: marker, atomically: true, encoding: .utf8)
        // The script polls every 0.2 s; the recording needs a moment to start up.
        wait(word == "start" ? 1.5 : 0.3)
    }

    func test_v1_open_book() throws {
        openHit(search: "leagues", title: "Twenty Thousand Leagues Under the Seas")
        wait(3)
        set("start")
        tap(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Weiterlesen' OR label BEGINSWITH 'Lesen'")
            ).firstMatch)
        _ = app.webViews.firstMatch.waitForExistence(timeout: 20)
        wait(4)
        set("stop")
    }

    func test_v2_comic_flip() throws {
        launch(["PROBE": "lesen"])
        wait(8)
        set("start")
        // Reading manga right to left: the left edge pages forward.
        for _ in 0..<3 {
            tapSpot(0.08, 0.5)
            wait(1.8)
        }
        app.swipeRight()
        wait(1.5)
        set("stop")
    }

    func test_v3_glossary_term() throws {
        glossaryTerm = "Nautilus"
        openHit(search: "leagues", title: "Twenty Thousand Leagues Under the Seas")
        tap(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Weiterlesen' OR label BEGINSWITH 'Lesen'")
            ).firstMatch)
        _ = app.webViews.firstMatch.waitForExistence(timeout: 20)
        wait(1)
        // Page to the terms, then the jump-in opens the sheet (ten seconds
        // after loading; a real tap does not arrive, see waitForGlossarySheet).
        turnForward(3)
        set("start")
        waitForGlossarySheet()
        wait(3)
        set("stop")
        turnBackAndClose(3)
    }

    func test_v4_switch_libraries() throws {
        launch(["BEREICH": "bibliothek"])
        wait(4)
        set("start")
        for name in ["Manga", "Bücher", "Hörbücher", "Podcasts", "Alle"] {
            tap(app.buttons[name].firstMatch)
            wait(1.6)
        }
        set("stop")
    }

    func test_v5_open_player() throws {
        launch(["PROBE": "mini"])
        wait(9)
        set("start")
        // The mini player sits above the tab bar.
        let bar = app.tabBars.firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: bar.midX, dy: bar.minY - 30)).tap()
        wait(3.5)
        app.swipeDown()
        wait(2)
        set("stop")
    }
}
