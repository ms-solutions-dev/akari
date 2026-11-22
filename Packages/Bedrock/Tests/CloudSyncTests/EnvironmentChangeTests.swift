import Foundation
import Testing

@testable import CloudSync

/// Television as a debug build in "Development", phone from TestFlight in
/// "Production": separate data. If a device changes environment, the zone is
/// missing there; that must not count as "deleted remotely".
@Suite("ProfileZone: change of the CloudKit environment")
@MainActor
struct EnvironmentChangeTests {

    let identifier = UUID()

    private func makeRecord(_ name: String, _ value: String) -> CloudRecord {
        CloudRecord(type: "Profileinstellung", name: name, fields: ["wert": .text(value)])
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "umgebung-\(UUID().uuidString).json")
    }

    @Test("A mirror from Development starts over in Production and uploads everything")
    func startedOver() async throws {
        let place = file()
        defer { try? FileManager.default.removeItem(at: place) }

        // Created, synced and confirmed in "Development".
        let development = CloudMock()
        let previously = ProfileZone(
            file: place, service: development.access("alex", environment: "Development"),
            zone: ZoneID(profile: identifier), unprompted: false)
        previously.write(makeRecord("name", "Alex"))
        previously.write(makeRecord("theme", "indigo"))
        await previously.equalSince()
        #expect(previously.pending == 0)

        // The same mirror, now against "Production", where the zone does not exist.
        let production = CloudMock()
        let after = ProfileZone(
            file: place, service: production.access("alex", environment: "Production"),
            zone: ZoneID(profile: identifier), unprompted: false)
        #expect(after.pending == 2, "everything is queued for upload again")
        await after.equalSince()

        #expect(after.removed == nil, "not declared deleted")
        #expect(after.pending == 0)
        #expect(production.content(ZoneID(profile: identifier, owner: "alex")).count == 2)
        #expect(after.record(type: "Profileinstellung", name: "name")?["wert"]?.text == "Alex")
    }

    @Test("In the same environment the guard changes nothing")
    func sameEnvironment() async throws {
        let place = file()
        defer { try? FileManager.default.removeItem(at: place) }
        let server = CloudMock()
        let first = ProfileZone(
            file: place, service: server.access("alex", environment: "Production"),
            zone: ZoneID(profile: identifier), unprompted: false)
        first.write(makeRecord("name", "Alex"))
        await first.equalSince()

        let again = ProfileZone(
            file: place, service: server.access("alex", environment: "Production"),
            zone: ZoneID(profile: identifier), unprompted: false)
        #expect(again.pending == 0)
        guard case .synced = again.state else {
            Issue.record("State \(again.state)")
            return
        }
    }
}
