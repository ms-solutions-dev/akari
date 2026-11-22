import XCTest

/// The profile sheet at the top right and everything below it. Accounts, storage, statistics,
/// notifications and licenses with real data; profiles, PIN and iCloud with mocks -
/// they create three profiles in memory and touch no iCloud account.
final class D_Profile: ScreenshotTestCase {

    /// Scrolls in the open sheet until the entry is tappable, and taps it.
    private func entry(_ name: String) {
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<6 where !(target.exists && target.isHittable) {
            app.swipeUp()
        }
        tap(target)
    }

    func test_39_profile_sheet() throws {
        launch(["PROBE": "konto"])
        snap("39-profilblatt", pause: 3)
    }

    func test_40_profile_sheet_bottom() throws {
        try portraitOnly()
        launch(["PROBE": "konto"])
        wait(2)
        app.swipeUp()
        app.swipeUp()
        snap("40-profilblatt-unten")
    }

    func test_41_storage() throws {
        try portraitOnly()
        launch(["PROBE": "konto"])
        wait(2)
        entry("Speicher")
        snap("41-speicher", pause: 3)
    }

    func test_42_statistics() throws {
        launch(["PROBE": "statistik"])
        snap("42-statistik", pause: 3)
    }

    func test_43_statistics_titles() throws {
        try portraitOnly()
        launch(["PROBE": "statistik-titel"])
        snap("43-statistik-titel", pause: 3)
    }

    func test_44_notifications() throws {
        try portraitOnly()
        launch(["PROBE": "konto"])
        wait(2)
        entry("Mitteilungen")
        snap("44-mitteilungen", pause: 2)
    }

    func test_45_licenses() throws {
        try portraitOnly()
        launch(["PROBE": "konto"])
        wait(2)
        entry("Lizenzen")
        snap("45-lizenzen", pause: 2)
    }

    func test_46_profiles_mocks() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "konto"])
        snap("46-profile-drei", pause: 3)
    }

    func test_47_profile_create() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "profilanlegen"])
        snap("47-profil-anlegen", pause: 3)
    }

    func test_48_pin() throws {
        launch(mocks: true, ["PROBE": "pin"])
        snap("48-pin", pause: 3)
    }

    func test_49_icloud_devices() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "wolke"])
        snap("49-icloud-geraete", pause: 3)
    }

    func test_50_device_add() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "geraet-hinzufuegen"])
        snap("50-geraet-hinzufuegen", pause: 3)
    }

    func test_51_child_profile_start() throws {
        try portraitOnly()
        launch(mocks: true, ["PROBE": "kind"])
        // `kind` also opens the sheet - the start behind it is the picture.
        tap(app.buttons["Fertig"].firstMatch, pause: 4)
        snap("51-kinderprofil-start", pause: 3)
    }
}
