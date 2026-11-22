import XCTest

/// The jank test: measures how many frames hang during the movements
/// that felt sluggish on iPhone - scrolling Start and Library, zoom into the detail,
/// dragging down the player. Instead of someone finding "does not feel smooth" on the device,
/// the calling script states it in numbers before the TestFlight build.
///
/// Always with mocks: the same data on every run, and no reading state on the server
/// moves. Only the device is meaningful - the simulator draws with the Mac and
/// shows at most coarse regressions.
@MainActor
final class Flow: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        app?.terminate()
    }

    private func launch(_ environment: [String: String] = [:]) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE", "-attrappen"]
        for (name, value) in environment { app.launchEnvironment["AKARI_\(name)"] = value }
        app.launch()
        self.app = app
        XCTAssert(app.tabBars.firstMatch.waitForExistence(timeout: 20), "die Hülle stand nicht")
        // Cover and light arrive later - the settled state is measured.
        settle(3)
    }

    private func settle(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.1))) }
    }

    private var options: XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.iterationCount = 5
        return o
    }

    func test_1_start_scroll() {
        launch()
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func test_2_library_scroll() {
        launch(["BEREICH": "bibliothek"])
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func test_3_detail_zoom() {
        launch()
        let cover = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Frankenstein'")).firstMatch
        XCTAssert(cover.waitForExistence(timeout: 10), "kein Cover zum Antippen")
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            cover.tap()
            settle(1.2)
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 5) { back.tap() }
            settle(1.2)
        }
    }

    func test_4_player_drag() {
        launch(["PROBE": "hoerbuch"])
        settle(2)
        // 100 pt down and release - under the threshold for closing, the sheet
        // springs back and can thus be dragged five times.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        measure(metrics: [XCTHitchMetric(application: app)], options: options) {
            start.press(
                forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 100)),
                withVelocity: .slow,
                thenHoldForDuration: 0.15)
            settle(0.6)
        }
    }
}
