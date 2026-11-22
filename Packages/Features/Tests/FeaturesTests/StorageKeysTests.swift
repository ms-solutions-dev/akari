import Foundation
import Testing

@testable import Features

/// UserDefaults keys and activity types keep their original spelling. Some of them equal a localization key
/// (`start.unten`, `mitteilungen.an`, …) and must not follow its translation. The expectations were written from
/// the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func userDefaultsKeys() {
        #expect(StartRow.lookupKey == "start.unten")
        #expect(Summary.automaticKey == "text.automatisch")
        #expect(NotificationChoice.onKey == "mitteilungen.an")
        #expect(NotificationChoice.subscriptionsKey == "mitteilungen.podcasts")
        #expect(ViewMode.storeKey == "library.ansicht")
        #expect(SearchHistory.storeKey == "search.verlauf")
        #expect(AuthorHeader.wikipediaKey == "autoren.wikipedia")
        #expect(PositionReporter.recordKey == "lesezeit.erfassen")
    }

    @Test func handoffAndNotificationKeys() {
        #expect(ReadingHandoff.kind == "dev.ms-solutions.akari.lesen")
        #expect(ReadingHandoff.linkKey == "link")
        #expect(SystemSender.linkKey == "link")
    }
}
