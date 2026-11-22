import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import OfflineStore

/// Scenario: the app is quit while fetching, the rest stays — the next attempt sends
/// `Range` and appends instead of starting over. Checked against a real `URLSession`
/// with a `URLProtocol` that plays the server: it reads the `Range` header and
/// answers 206 with the rest.
@Suite("File fetcher: resuming", .serialized)
struct FileFetcherTests {

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServer.self]
        return URLSession(configuration: configuration)
    }

    @Test("If a part is there, the second attempt fetches only the rest (206) and the file is complete")
    func resumes() async throws {
        let target = FileManager.default.temporaryDirectory.appending(path: "holer-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RangeServer.content.prefix(300_000).write(to: target)
        RangeServer.requests = []
        let bytes = try await FileFetcher.fetch(
            URL(string: "https://buecher.example/api/v1/books/7/content")!, headerLines: ["X-Kennung": "k"],
            transport: session(), to: target, rangeCapable: true
        ) { _ in }
        #expect(bytes == Int64(RangeServer.content.count))
        #expect(try Data(contentsOf: target) == RangeServer.content)
        #expect(RangeServer.requests.count == 1)
        #expect(RangeServer.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=300000-")
        #expect(RangeServer.requests.first?.value(forHTTPHeaderField: "X-Kennung") == "k")
    }

    @Test("Without range support everything comes again — and the old part is replaced")
    func fromScratch() async throws {
        let target = FileManager.default.temporaryDirectory.appending(path: "holer-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1_000).write(to: target)
        RangeServer.requests = []
        let bytes = try await FileFetcher.fetch(
            URL(string: "https://buecher.example/api/v1/books/7/content")!, headerLines: [:],
            transport: session(), to: target, rangeCapable: false
        ) { _ in }
        #expect(bytes == Int64(RangeServer.content.count))
        #expect(try Data(contentsOf: target) == RangeServer.content)
        #expect(RangeServer.requests.first?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test("A server status error is an error of its own that the reader can interpret")
    func status() async throws {
        let transport = MockTransport()
        transport.answer("GET", "/x", with: .init(status: 503, data: Data()))
        let target = FileManager.default.temporaryDirectory.appending(path: "holer-\(UUID().uuidString).bin")
        await #expect(throws: FileFetcher.Failure.status(503)) {
            _ = try await FileFetcher.fetch(
                URL(string: "https://x.example/x")!, headerLines: [:], transport: transport, to: target,
                rangeCapable: true
            ) { _ in }
        }
    }
}

/// Plays a server that understands `Range`: 200 with everything, 206 with the rest.
final class RangeServer: URLProtocol, @unchecked Sendable {

    static let content = Data((0..<800_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RangeServer.requests.append(request)
        let fullContent = RangeServer.content
        var status = 200
        var data = fullContent
        var header = ["Content-Length": String(fullContent.count), "Accept-Ranges": "bytes"]
        if let area = request.value(forHTTPHeaderField: "Range"), area.hasPrefix("bytes="),
            let from = Int(area.dropFirst("bytes=".count).split(separator: "-").first ?? "")
        {
            status = 206
            data = fullContent[from...]
            header["Content-Length"] = String(data.count)
            header["Content-Range"] = "bytes \(from)-\(fullContent.count - 1)/\(fullContent.count)"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: header)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
