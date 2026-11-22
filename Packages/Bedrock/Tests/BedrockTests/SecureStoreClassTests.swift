import Security
import Testing

@testable import Bedrock

/// Pairing credentials are bound to the device, accesses are not.
@Suite("SecureStore: access class")
struct SecureStoreClassTests {

    @Test("By default an entry travels with the backup, a bound one does not")
    func accessClass() {
        #expect(SecureStore().accessClass == kSecAttrAccessibleAfterFirstUnlock)
        #expect(
            SecureStore(onlyThisDevice: true).accessClass
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
}
