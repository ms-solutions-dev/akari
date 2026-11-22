import XCTest

/// First start, sign-in, certificate - all with mocks, because a signed-in
/// device never shows these screens again and no real credentials may appear in any field.
final class A_Access: ScreenshotTestCase {

    func test_01_welcome() throws {
        launch(mocks: true, ["PROBE": "willkommen"])
        snap("01-willkommen")
    }

    func test_02_sign_in_form() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "willkommen"])
        // The mock server rows are already signed in - an empty form
        // only appears for a new OPDS catalog.
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Katalog hinzufügen'")).firstMatch)
        snap("02-anmeldung-formular")
    }

    func test_03_scan_code() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "willkommen"])
        // There is no camera in the simulator - the sheet then offers pasting.
        tap(app.buttons["Code vom Server scannen"].firstMatch)
        snap("03-code-scannen", pause: 3)
    }

    func test_04_certificate_prompt() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "stoerung:zertifikat"])
        snap("04-zertifikatsfrage", pause: 5)
    }
}
