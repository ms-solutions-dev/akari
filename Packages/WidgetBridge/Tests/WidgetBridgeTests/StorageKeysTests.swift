import Foundation
import Testing

@testable import WidgetBridge

/// The App Group and the widget kinds are shared with the widget extension and with widgets users have already
/// placed on their Home Screen. The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func appGroupAndWidgetKinds() {
        #expect(SnapshotStore.cluster == "group.dev.ms-solutions.akari")
        #expect(SnapshotStore.widgetKind == "dev.ms-solutions.akari.weiterlesen")
        #expect(SnapshotStore.continueListeningKind == "dev.ms-solutions.akari.weiterhoeren")
        #expect(SnapshotStore.statisticsKind == "dev.ms-solutions.akari.lesestatistik")
    }
}
