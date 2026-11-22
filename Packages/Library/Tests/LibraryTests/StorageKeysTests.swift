import Foundation
import Testing

@testable import Library

/// Storage keys and CloudKit record types keep their original spelling. The expectations were written from the
/// code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func keys() {
        #expect(LibraryService.bookSeriesKey == "library.reihen")
        #expect(SavedList.storeKey == "gemerkt")
        #expect(SavedList.type == "Merkeintrag")
    }
}
