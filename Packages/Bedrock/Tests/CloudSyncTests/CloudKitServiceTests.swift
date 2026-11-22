import CloudKit
import Testing

@testable import CloudSync

/// Which CloudKit errors in the result of a record concern only that record, and
/// which still throw the whole batch.
@Suite("CloudKitService: individual errors")
struct CloudKitServiceTests {

    @Test(
        "Schema, Eindeutigkeit, Verweis und Datei betreffen nur den Satz",
        arguments: [
            CKError.Code.invalidArguments, .serverRejectedRequest, .constraintViolation,
            .referenceViolation, .assetFileNotFound, .assetFileModified,
        ])
    func single(_ code: CKError.Code) {
        #expect(CloudKitService.affectsOnlyTheRecord(CKError(code)))
    }

    @Test(
        "Netz, Konto, Kontingent, Rechte und Zone bleiben Gesamtfehler",
        arguments: [
            CKError.Code.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
            .notAuthenticated, .quotaExceeded, .permissionFailure, .zoneNotFound, .userDeletedZone,
            .limitExceeded, .batchRequestFailed, .zoneBusy,
        ])
    func total(_ code: CKError.Code) {
        #expect(!CloudKitService.affectsOnlyTheRecord(CKError(code)))
    }
}

/// When `serverRejectedRequest` does hit the whole batch after all.
@Suite("CloudKitService: results of a batch")
struct CloudKitServiceResultTests {

    let zone = CKRecordZone.ID(zoneName: "profil", ownerName: CKCurrentUserDefaultName)

    func identifier(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone) }

    func refused() -> Result<CKRecord, any Error> { .failure(CKError(.serverRejectedRequest)) }

    @Test("All records refused, none through: the batch throws as a whole")
    func allRefused() {
        let a = identifier("a")
        let b = identifier("b")
        #expect(throws: CloudError.self) {
            try CloudKitService.results([a, b], [a: refused(), b: refused()])
        }
    }

    @Test("A single refused record remains its rejection")
    func singleRefused() throws {
        let a = identifier("a")
        let results = try CloudKitService.results([a], [a: refused()])
        guard case .rejected = results.first else {
            Issue.record("\(results)")
            return
        }
    }

    @Test("One through, one refused: only that one is rejected")
    func mixed() throws {
        let a = identifier("a")
        let b = identifier("b")
        let results = try CloudKitService.results(
            [a, b], [a: .success(CKRecord(recordType: "Neuling", recordID: a)), b: refused()])
        guard case .stored = results[0], case .rejected = results[1] else {
            Issue.record("\(results)")
            return
        }
    }

    @Test("All with a missing schema (invalidArguments): each record rejected individually")
    func allWithoutSchema() throws {
        let a = identifier("a")
        let b = identifier("b")
        let missing: Result<CKRecord, any Error> = .failure(CKError(.invalidArguments))
        let results = try CloudKitService.results([a, b], [a: missing, b: missing])
        #expect(results.allSatisfy { if case .rejected = $0 { true } else { false } })
    }
}
