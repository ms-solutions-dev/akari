import Foundation
import SourcesKit
import SourcesKitMocks
import Synchronization

/// A transport for Kavita fetches that differ only in the query.
///
/// The ``MockTransport`` chooses by method and path — but Kavita asks
/// `/api/Series/volumes?seriesId=…` per series, six at a time, and the order
/// is then random. The router looks up `volumes-<seriesId>.json` in the
/// recordings and passes everything else on to the mock transport.
final class KavitaRoutingTransport: Transport, Sendable {
    let remainder = MockTransport()
    private let bundle: Bundle
    private let asked = Mutex<[URLRequest]>([])
    /// Series whose recording is named differently — the book volume with a state is stored as
    /// `volumes-buch.json`.
    private let names: [String: String]

    init(bundle: Bundle = .module, names: [String: String] = ["395": "volumes-buch.json"]) {
        self.bundle = bundle
        self.names = names
    }

    /// Everything that was asked — including what the router answered itself.
    var requests: [URLRequest] { asked.withLock { $0 } }

    /// How often a series was asked for its volumes.
    var volumeFetches: Int {
        requests.filter { $0.url?.path() == "/api/Series/volumes" }.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        asked.withLock { $0.append(request) }
        if request.url?.path() == "/api/Series/volumes",
            let series = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "seriesId" })?.value
        {
            let response = try MockTransport.recording(
                names[series] ?? "volumes-\(series).json", from: bundle)
            let http = HTTPURLResponse(
                url: request.url!, statusCode: response.status, httpVersion: "HTTP/2",
                headerFields: response.headerLines)!
            return (response.data, http)
        }
        return try await remainder.send(request)
    }
}
