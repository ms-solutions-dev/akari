import Foundation
import Testing

@testable import DesignSystem

/// Storage keys keep their original spelling. The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func keys() {
        #expect(Appearance.storeKey == "app.appearance")
        #expect(LanguageChoice.storeKey == "app.language")
        #expect(LanguageChoice.systemKey == "AppleLanguages")
        #expect(ThemeChoice.storeKey == "app.theme")
    }
}
