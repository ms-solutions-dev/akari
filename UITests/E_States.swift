import XCTest

/// Faults, empty and loading states - all with mocks that the
/// fault probe lets fail artificially (`AKARI_PROBE=stoerung:<case>`).
final class E_States: ScreenshotTestCase {

    func test_52_fault_one_server_down() throws {
        launch(mocks: true, ["PROBE": "stoerung:komga-aus"])
        snap("52-stoerung-ein-server-aus", pause: 6)
    }

    func test_53_fault_all_down() throws {
        launch(mocks: true, ["PROBE": "stoerung:alle-aus"])
        snap("53-stoerung-alle-aus", pause: 6)
    }

    func test_54_fault_expired() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "stoerung:401"])
        snap("54-stoerung-anmeldung-abgelaufen", pause: 6)
    }

    func test_55_fault_server_wrong_answer() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "stoerung:502"])
        snap("55-stoerung-502", pause: 6)
    }

    func test_56_fault_slow() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "stoerung:langsam"])
        snap("56-stoerung-langsam", pause: 6)
    }

    func test_57_fault_page_missing() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "stoerung:seiten"])
        snap("57-stoerung-seite-fehlt", pause: 16)
    }

    func test_58_fault_conflict() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "stoerung:konflikt"])
        snap("58-stoerung-lesestand-konflikt", pause: 8)
    }

    func test_59_slow_start() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "stoerung:langsam-start"])
        snap("59-langsamer-start", pause: 1.5)
    }

    func test_60_empty_search() throws {
        try portraitOnly()
        launch(mocks: true, ["BEREICH": "suche", "SUCHE": "xyzqw"])
        snap("60-leer-suche-nichts-gefunden", pause: 2)
    }

    func test_61_mocks_start() throws {
        // The start with the mocks: shows how the placeholder covers look
        // that appear in the fault screens.
        try portraitOnly()
        launch(mocks: true)
        snap("61-attrappen-start", pause: 3)
    }
}
