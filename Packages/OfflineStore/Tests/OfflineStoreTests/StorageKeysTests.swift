import Foundation
import Testing

@testable import OfflineStore

/// Storage keys keep their original spelling. The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func keys() {
        #expect(Cache.limitKey == "vorrat.obergrenze")
        #expect(Cache.preloadAtHomeKey == "vorrat.vorabDaheim")
    }
}
