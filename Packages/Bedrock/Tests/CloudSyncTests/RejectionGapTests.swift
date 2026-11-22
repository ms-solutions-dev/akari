import Foundation
import Testing

@testable import CloudSync

/// A service that holds the pass **in the middle of saving**: for the race
/// "write while the same record is just going up". It also counts how often a
/// record was sent up, so a tight retry loop shows.
final class HoldingService: CloudService, @unchecked Sendable {
    let inner: CloudMock.Access
    private let lock = NSLock()
    private var inPass = false
    private var inPassContinuation: CheckedContinuation<Void, Never>?
    private var proceedAllowed = false
    private var proceedContinuation: CheckedContinuation<Void, Never>?
    private var holds: Bool
    private var sent: [RecordName: Int] = [:]

    /// - Parameter holds: whether the first save holds until ``proceed()`` comes.
    init(_ inner: CloudMock.Access, holds: Bool = true) {
        self.inner = inner
        self.holds = holds
    }

    /// How often this record has been sent up so far.
    func attempts(_ name: RecordName) -> Int { lock.withLock { sent[name, default: 0] } }

    func waitForPass() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if inPass { c.resume() } else { inPassContinuation = c }
            }
        }
    }

    func proceed() {
        lock.withLock {
            proceedAllowed = true
            proceedContinuation?.resume()
            proceedContinuation = nil
        }
    }

    func accountStatus() async -> AccountStatus { await inner.accountStatus() }
    func accountChanges() -> AsyncStream<Void> { inner.accountChanges() }
    func createNew(_ zone: ZoneID) async throws(CloudError) { try await inner.createNew(zone) }
    func erase(_ zone: ZoneID) async throws(CloudError) { try await inner.erase(zone) }
    func zones(shared: Bool) async throws(CloudError) -> [ZoneID] {
        try await inner.zones(shared: shared)
    }
    func databaseChanges(
        shared: Bool, since marker: Data?
    ) async throws(CloudError) -> DatabaseChanges {
        try await inner.databaseChanges(shared: shared, since: marker)
    }
    func changes(_ zone: ZoneID, since marker: Data?) async throws(CloudError) -> Changes {
        try await inner.changes(zone, since: marker)
    }
    func fetchRecords(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) -> [CloudRecord] {
        try await inner.fetchRecords(names, in: zone)
    }
    func persist(
        _ records: [CloudRecord], in zone: ZoneID
    ) async throws(CloudError) -> [StoreResult] {
        lock.withLock { for makeRecord in records { sent[makeRecord.id, default: 0] += 1 } }
        let result = try await inner.persist(records, in: zone)
        let held = lock.withLock { () -> Bool in
            guard holds else { return false }
            holds = false
            inPass = true
            inPassContinuation?.resume()
            inPassContinuation = nil
            return true
        }
        if held {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    if proceedAllowed { c.resume() } else { proceedContinuation = c }
                }
            }
        }
        return result
    }
    func erase(_ names: [RecordName], in zone: ZoneID) async throws(CloudError) {
        try await inner.erase(names, in: zone)
    }
    func createPublic(_ makeRecord: CloudRecord) async throws(CloudError) {
        try await inner.createPublic(makeRecord)
    }
    func readPublic(_ name: RecordName) async throws(CloudError) -> CloudRecord? {
        try await inner.readPublic(name)
    }
    func erasePublic(_ name: RecordName) async throws(CloudError) {
        try await inner.erasePublic(name)
    }
    func subscribe() async throws(CloudError) { try await inner.subscribe() }
    func interpret(push: [AnyHashable: Any]) -> PushInterpretation? { inner.interpret(push: push) }
    func share(_ zone: ZoneID, title: String) async throws(CloudError) -> Sharing {
        try await inner.share(zone, title: title)
    }
    func sharing(_ zone: ZoneID) async throws(CloudError) -> Sharing? {
        try await inner.sharing(zone)
    }
    func remove(participant: String, from zone: ZoneID) async throws(CloudError) {
        try await inner.remove(participant: participant, from: zone)
    }
    func endSharing(_ zone: ZoneID) async throws(CloudError) {
        try await inner.endSharing(zone)
    }
    func sharingMetadata(_ url: URL) async throws(CloudError) -> SharingMetadata {
        try await inner.sharingMetadata(url)
    }
    func accept(_ metadata: SharingMetadata) async throws(CloudError) -> ZoneID {
        try await inner.accept(metadata)
    }
    func leave(_ zone: ZoneID) async throws(CloudError) { try await inner.leave(zone) }
}

/// The gaps around ``StoreResult/rejected(_:)``, each first red against the
/// state before the fix.
@Suite("ProfileZone: gaps in the individual rejection")
@MainActor
struct RejectionGapTests {

    let server = CloudMock()
    let identifier = UUID()

    var serverZone: ZoneID { ZoneID(profile: identifier, owner: "alex") }
    let newcomer = RecordName(type: "Neuling", name: "n")

    func makeRecord(_ name: String, _ value: String, type: String = "Neuling") -> CloudRecord {
        CloudRecord(type: type, name: name, fields: ["wert": .text(value)])
    }

    func zone(file: URL? = nil, service: (any CloudService)? = nil) -> ProfileZone {
        ProfileZone(
            file: file, service: service ?? server.access("alex"), zone: ZoneID(profile: identifier),
            unprompted: false)
    }

    func value(_ z: ProfileZone) -> String? { z.record(type: "Neuling", name: "n")?["wert"]?.text }

    func serverValue() -> String? { server.content(serverZone).first { $0.name == "n" }?["wert"]?.text }

    /// Gap 1: the schema arrives, the app keeps running, nobody touches the record,
    /// and a pass that brings changes from the server tries it again.
    @Test(
        "Schema nachgeliefert, kein Neustart, keine Änderung: der nächste Gang mit Neuigkeiten trägt ihn hinauf"
    )
    func noChangeNoRestart() async {
        server.deny(type: "Neuling")
        let z = zone()
        z.write(makeRecord("n", "neu"))
        await z.equalSince()
        #expect(z.rejected[newcomer] != nil && server.content(serverZone).isEmpty)

        server.deny(type: "Neuling", reason: nil)
        z.write(makeRecord("x", "1", type: "Profileinstellung"))
        await z.equalSince()
        await z.equalSince()
        #expect(serverValue() == "neu", "without a restart and without a change to the record it stays down")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    /// Gap 1, without news: after the deadline ``ProfileZone/retryInterval`` the
    /// record goes up again in the next pass; not before, and never more than once
    /// per pass.
    @Test("Without news: retry only after the deadline, and at most once per pass")
    func afterTheDeadline() async {
        server.deny(type: "Neuling")
        let gate = HoldingService(server.access("alex"), holds: false)
        let z = zone(service: gate)
        var now = Date()
        z.clock = { now }
        z.write(makeRecord("n", "neu"))
        await z.equalSince()
        #expect(gate.attempts(newcomer) == 1)

        await z.equalSince()
        #expect(gate.attempts(newcomer) == 1, "no hammering within the deadline")

        now += ProfileZone.retryInterval
        await z.equalSince()
        #expect(
            gate.attempts(newcomer) == 2, "exactly one attempt after the deadline, no loop within the pass")
        #expect(z.rejected[newcomer] != nil && z.pending == 0)

        server.deny(type: "Neuling", reason: nil)
        await z.equalSince()
        #expect(serverValue() == nil, "the deadline runs from the last attempt")
        now += ProfileZone.retryInterval
        await z.equalSince()
        #expect(serverValue() == "neu")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    /// Gap 2: another device writes the same record after the schema is there. The
    /// rejected state is a pending write, so the type's rule applies, here
    /// ``MergeRule/younger``: the own, younger state wins.
    @Test("Downloading against a rejected, younger state: the own one wins and goes up")
    func downloadOwnYounger() async {
        server.deny(type: "Neuling")
        let file = FileManager.default.temporaryDirectory.appending(path: "wolke-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let iphone = zone(file: file)
        iphone.write(makeRecord("n", "lokal"), now: Date().addingTimeInterval(100))
        await iphone.equalSince()
        #expect(iphone.rejected[newcomer] != nil)

        server.deny(type: "Neuling", reason: nil)
        let ipad = zone()
        ipad.write(makeRecord("n", "fremd"))
        await ipad.equalSince()
        #expect(serverValue() == "fremd")

        await iphone.equalSince()
        #expect(value(iphone) == "lokal", "the younger state that never got up is gone")
        #expect(serverValue() == "lokal", "and it goes up in the same pass")
        #expect(iphone.rejected.isEmpty && iphone.pending == 0)
        #expect(zone(file: file).pending == 0, "the restart enqueues nothing any more")
    }

    /// Gap 2, the other way round: the foreign state is younger and overwrites the
    /// one that never got up; the note drops, nothing stays orphaned.
    @Test("Downloading against a rejected, older state: the foreign one wins, the note drops")
    func downloadForeignYounger() async {
        server.deny(type: "Neuling")
        let file = FileManager.default.temporaryDirectory.appending(path: "wolke-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let iphone = zone(file: file)
        iphone.write(makeRecord("n", "lokal"), now: Date().addingTimeInterval(-100))
        await iphone.equalSince()
        #expect(iphone.rejected[newcomer] != nil)

        server.deny(type: "Neuling", reason: nil)
        let ipad = zone()
        ipad.write(makeRecord("n", "fremd"))
        await ipad.equalSince()

        await iphone.equalSince()
        #expect(value(iphone) == "fremd")
        #expect(serverValue() == "fremd")
        #expect(iphone.rejected.isEmpty, "the note is still there although the record is now the foreign one")
        #expect(zone(file: file).pending == 0, "the restart enqueues the overwritten record again")
    }

    /// Gap 2, remote deletion: a rejected state is a pending write and, like any
    /// other, wins against the other device's deletion.
    @Test("Remote deletion against a rejected state: the request stays and goes up")
    func deleteRemotely() async {
        let iphone = zone()
        iphone.write(makeRecord("n", "alt"))
        await iphone.equalSince()
        #expect(serverValue() == "alt")

        server.deny(type: "Neuling")
        iphone.write(makeRecord("n", "lokal"))
        await iphone.equalSince()
        #expect(iphone.rejected[newcomer] != nil)

        server.deny(type: "Neuling", reason: nil)
        let ipad = zone()
        await ipad.equalSince()
        ipad.erase(type: "Neuling", name: "n")
        await ipad.equalSince()
        #expect(server.content(serverZone).isEmpty)

        await iphone.equalSince()
        #expect(value(iphone) == "lokal")
        #expect(serverValue() == "lokal")
        #expect(iphone.rejected.isEmpty && iphone.pending == 0)
    }

    /// Gap 3: the record is changed while its old state comes back rejected; the
    /// newer change stays a request and goes up in the same pass.
    @Test("Writing during the pass: the newer change does not drop out of the queue with the rejection")
    func raceWriteDuringPass() async {
        server.deny(type: "Neuling")
        let gate = HoldingService(server.access("alex"))
        let z = zone(service: gate)
        z.write(makeRecord("n", "alt"))
        let pass = Task { await z.equalSince() }
        await gate.waitForPass()
        server.deny(type: "Neuling", reason: nil)
        z.write(makeRecord("n", "neu"))
        #expect(z.pending == 1)
        gate.proceed()
        await pass.value

        #expect(serverValue() == "neu", "the value neu never goes up")
        #expect(z.rejected.isEmpty && z.pending == 0)
    }

    /// The same race with deletion: the record is gone, and the rejection of its old
    /// state must not leave an orphaned note.
    @Test("Deleting during the pass: no orphaned note")
    func raceDeleteDuringPass() async {
        server.deny(type: "Neuling")
        let gate = HoldingService(server.access("alex"))
        let z = zone(service: gate)
        z.write(makeRecord("n", "alt"))
        let pass = Task { await z.equalSince() }
        await gate.waitForPass()
        z.erase(type: "Neuling", name: "n")
        gate.proceed()
        await pass.value

        #expect(value(z) == nil)
        #expect(z.rejected.isEmpty, "note for a record that no longer exists")
        #expect(z.pending == 0)
    }
}
