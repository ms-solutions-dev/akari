import Foundation
import Testing

@testable import PerformanceDiagnostics

/// Storage keys keep their original spelling (this one equals a localization key and must not follow its
/// translation). The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func keys() {
        #expect(Performance.recordKey == "diagnose.aufzeichnen")
    }
}
