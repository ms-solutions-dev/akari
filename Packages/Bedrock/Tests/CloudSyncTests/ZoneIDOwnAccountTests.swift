import Foundation
import Testing

@testable import CloudSync

/// Same Apple ID on both devices: the accepted share carried `__defaultOwner__`
/// as owner and was looked up in the shared database.
@Suite("ZoneID: the own account is not a foreign owner")
struct ZoneIDOwnAccountTests {

    @Test("The placeholder of the own account does not make a shared zone")
    func ownAccount() {
        let zone = ZoneID(name: "profil-x", owner: "__defaultOwner__")
        #expect(!zone.shared)
        #expect(ZoneID(name: "profil-x", owner: "_abc123").shared)
    }

    @Test("A stored mirror with the placeholder reads as an own zone")
    func stored() throws {
        let json = Data(#"{"name":"profil-x","besitzer":"__defaultOwner__"}"#.utf8)
        let zone = try JSONDecoder().decode(ZoneID.self, from: json)
        #expect(!zone.shared)
        #expect(zone == ZoneID(name: "profil-x"))
    }
}
