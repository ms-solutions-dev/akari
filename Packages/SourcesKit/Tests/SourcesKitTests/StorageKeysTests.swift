import Foundation
import Testing

@testable import SourcesKit

/// Identifier prefixes that end up in server data and in the catalog cache keep their original spelling. The
/// expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func prefixes() {
        #expect(CollectionID.autoPrefix == "auto-")
    }
}
