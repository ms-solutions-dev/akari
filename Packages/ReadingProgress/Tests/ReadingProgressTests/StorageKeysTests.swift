import Foundation
import Testing

@testable import ReadingProgress

/// Storage keys and CloudKit record types keep their original spelling. The expectations were written from the
/// code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func keys() {
        #expect(ReadingTimeLog.storeKey == "lesezeit")
        #expect(ReadingTimeLog.type == "Lesesitzung")
    }
}
