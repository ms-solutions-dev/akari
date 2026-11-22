import XCTest

/// The README / store set on iPad: the screens that need landscape, which `simctl` cannot
/// turn. Runs with the sample data (`-attrappen`), in English, and only when
/// `SCREENSHOT_README=1` (from the maintainer's `readme-screens.sh`) - the ordinary screenshot run
/// skips it. Language: `SCREENSHOT_SPRACHE=en`, landscape: `SCREENSHOT_QUER=1`.
///
/// The test does not take the picture itself: `XCUIScreen` returns landscape shots as raw
/// portrait pixels, sometimes upside down. It writes the name into the marker file
/// (`SCREENSHOT_MARKE`), the script takes `simctl io screenshot` and answers in
/// `<marker>.ok`; the test waits for that.
final class G_Readme: ScreenshotTestCase {

    private var marker: String? { ProcessInfo.processInfo.environment["SCREENSHOT_MARKE"] }

    private func readmeOnly() throws {
        if ProcessInfo.processInfo.environment["SCREENSHOT_README"] != "1" {
            throw XCTSkip("nur für das README")
        }
    }

    private func shoot(_ name: String, pause: Double) {
        wait(pause)
        guard let marker else { return snap("readme-ipad-" + name, pause: 0) }
        let answer = marker + ".ok"
        try? FileManager.default.removeItem(atPath: answer)
        try? name.write(toFile: marker, atomically: true, encoding: .utf8)
        let end = Date().addingTimeInterval(40)
        while Date() < end {
            if (try? String(contentsOfFile: answer, encoding: .utf8)) == name { return }
            wait(0.2)
        }
        XCTFail("keine Antwort des Skripts für \(name)")
    }

    func test_r1_library() throws {
        try readmeOnly()
        launch(mocks: true, ["BEREICH": "bibliothek"])
        shoot("library", pause: 5)
    }

    func test_r2_book() throws {
        try readmeOnly()
        launch(mocks: true, ["PROBE": "buch"])
        shoot("book", pause: 12)
    }

    func test_r3_comic() throws {
        try readmeOnly()
        launch(mocks: true, ["PROBE": "lesen"])
        shoot("comic", pause: 10)
    }

    func test_r4_start() throws {
        try readmeOnly()
        launch(mocks: true)
        shoot("start", pause: 5)
    }

    func test_r5_glossary() throws {
        try readmeOnly()
        glossaryTerm = "Inspector Gregory"
        launch(mocks: true, ["PROBE": "buch"])
        shoot("glossary", pause: 22)
    }
}
