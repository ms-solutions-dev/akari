import Foundation
import Testing

@testable import Bedrock

/// Storage keys keep their original spelling. The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func keys() {
        #expect(DebugMode.storageKey == "diagnostics.debug")
        #expect(DeviceIdentity.storageKey == "device.id")
        #expect(Theme.storageKey == "appearance.theme")
    }
}
