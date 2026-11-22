import Foundation
import Testing

@testable import ComicReader

/// Storage keys keep their original spelling. The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func keys() {
        #expect(ReadingDefaults.defaultDirectionKey == "leser.vorgabe.richtung")
    }
}
