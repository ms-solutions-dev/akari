import XCTest

/// One-off: page the book back to screen page 8.
final class Z_Reset: ScreenshotTestCase {
    func test_zz_reset() throws {
        guard ProcessInfo.processInfo.environment["SCREENSHOT_RUECK"] != nil else { throw XCTSkip("aus") }
        openHit(search: "leagues", title: "Twenty Thousand Leagues Under the Seas")
        tap(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Weiterlesen' OR label == 'Lesen'"))
                .firstMatch)
        _ = app.webViews.firstMatch.waitForExistence(timeout: 20)
        wait(4)
        snap("vorher", pause: 0.5)
        let target = Int(ProcessInfo.processInfo.environment["SCREENSHOT_RUECK"]!)!
        for _ in 0..<target { tapSpot(0.08, 0.5); wait(1.2) }
        // The state is written delayed - wait, then close the reader properly.
        wait(12)
        snap("nachher", pause: 0.5)
        tapSpot(0.5, 0.5)
        wait(1.5)
        tapSpot(0.07, 0.085)
        wait(6)
        snap("geschlossen", pause: 0.5)
    }
}
