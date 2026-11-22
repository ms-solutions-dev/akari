import Foundation
import SourcesKitMocks
import Testing

@testable import AudioPlayer

@Suite("Audio bridge")
struct AudioBridgeTests {

    private func bridge() async throws -> (AudioBridge, MockTransport, Data) {
        let transport = MockTransport()
        let data = Data((0..<10_000).map { UInt8($0 % 251) })
        transport.answer(
            "GET", "/api/items/7/file/1", with: .init(data: data, headerLines: ["Content-Type": "audio/mpeg"])
        )
        let b = try AudioBridge(headerLines: ["Authorization": "Bearer geheim"], transport: transport)
        _ = try await b.launch()
        b.set(tracks: [URL(string: "https://hoerbuch.example/api/items/7/file/1")!])
        return (b, transport, data)
    }

    @Test("Whole, with range, with open end, HEAD - and the header line goes upstream")
    func fetches() async throws {
        let (b, transport, data) = try await bridge()
        defer { b.stop() }
        let session = URLSession(configuration: .ephemeral)

        let (whole, a1) = try await session.data(from: b.address(track: 0))
        #expect((a1 as? HTTPURLResponse)?.statusCode == 200)
        #expect(whole == data)
        #expect((a1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer geheim")

        var part = URLRequest(url: b.address(track: 0))
        part.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (chunk, a2) = try await session.data(for: part)
        #expect((a2 as? HTTPURLResponse)?.statusCode == 206)
        #expect(chunk == data[100...199])
        #expect((a2 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/10000")

        var remainder = URLRequest(url: b.address(track: 0))
        remainder.setValue("bytes=9900-", forHTTPHeaderField: "Range")
        let (end, _) = try await session.data(for: remainder)
        #expect(end.count == 100)

        var header = URLRequest(url: b.address(track: 0))
        header.httpMethod = "HEAD"
        let (empty, a3) = try await session.data(for: header)
        #expect(empty.isEmpty)
        #expect((a3 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "10000")

        let (_, a4) = try await session.data(from: b.address(track: 5))
        #expect((a4 as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("Ranges are read as in the standard")
    func areas() {
        #expect(AudioBridge.area("bytes=0-1", total: 10)! == (0, 1))
        #expect(AudioBridge.area("bytes=5-", total: 10)! == (5, 9))
        #expect(AudioBridge.area("bytes=-3", total: 10)! == (7, 9))
        #expect(AudioBridge.area("bytes=0-99", total: 10)! == (0, 9))
        #expect(AudioBridge.area("bytes=12-", total: 10) == nil)
        #expect(AudioBridge.area(nil, total: 10) == nil)
    }
}
