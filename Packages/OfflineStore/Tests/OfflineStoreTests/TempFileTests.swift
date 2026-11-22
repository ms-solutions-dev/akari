import Foundation
import SourcesKitMocks
import Testing

@testable import OfflineStore

@Suite("Zwischendatei")
struct TempFileTests {

    @Test("Fetched, stored, the second time from the store")
    func fetchesFile() async throws {
        let transport = MockTransport()
        transport.answer(
            "GET", "/api/v1/books/9/content", with: .init(data: Data(repeating: 7, count: 5_000)))
        let address = URL(string: "https://buecher.example/api/v1/books/9/content")!
        try? FileManager.default.removeItem(at: TempFile.path(for: address))
        #expect(!TempFile.present(address))
        let file = try await TempFile.fetch(
            address, size: 5_000, rangeCapable: true, headerLines: [:], transport: transport)
        #expect(TempFile.present(address))
        #expect(try Data(contentsOf: file).count == 5_000)
        _ = try await TempFile.fetch(
            address, size: nil, rangeCapable: true, headerLines: [:], transport: transport)
        #expect(transport.requests.count == 1)
        try? FileManager.default.removeItem(at: file)
    }
}
