import Foundation
import Testing

@testable import AudiobookshelfKit

/// Stored and wire formats keep their original (German) keys. Renaming a Swift property must
/// never change what is written to disk, the Keychain or iCloud, or what is decoded from them.
/// Every expectation below was generated from the code as it was before the English rename.
@Suite struct WireFormatTests {
    @Test func codingKeys() {
        #expect(
            Set(AudiobookshelfAccount.CodingKeys.allCases.map(\.rawValue)) == [
                "benutzername", "darfHolen", "nutzerId", "server", "token",
            ])
    }

}
