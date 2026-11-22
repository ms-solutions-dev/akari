import Foundation
import Testing

@testable import CloudSync

/// CloudKit record types and field names are part of the production schema (`cloudkit/schema.ckdb`) and of
/// every installed app's data. The expectations were written from the code before the English rename.
@MainActor @Suite struct StorageKeysTests {
    @Test func cloudKitNames() {
        #expect(CloudHub.settingType == "Profileinstellung")
        #expect(CloudHub.deviceType == "Geraet")
        #expect(CloudHub.nameKey == "name")
        #expect(CloudHub.colorKey == "farbe")
        #expect(CloudHub.participantPrefix == "teilnehmer.")
    }
}
