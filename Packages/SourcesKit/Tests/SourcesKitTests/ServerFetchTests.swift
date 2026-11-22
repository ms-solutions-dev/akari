import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@Suite("Server fetch")
struct ServerFetchTests {
    let source = SourceID(provider: .komga, server: "comics.example")

    private func makeFetch(_ transport: MockTransport) -> ServerFetch {
        ServerFetch(baseURL: URL(string: "https://comics.example")!, source: source, transport: transport)
    }

    struct Answer: Decodable, Equatable {
        let id: String
        let created: Date
    }

    @Test("Path, query, body and header lines end up in the request")
    func request() throws {
        let a = makeFetch(MockTransport())
        let request = try a.request(
            "api/v1/books/list", method: "POST", json: ["x": 1],
            query: [URLQueryItem(name: "size", value: "1000")],
            headerLines: ["X-API-Key": "k"])
        #expect(request.url?.absoluteString == "https://comics.example/api/v1/books/list?size=1000")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "k")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(#"{"x":1}"#.utf8))
    }

    @Test("JSON with Komga and Grimmory data is read")
    func json() async throws {
        let t = MockTransport()
        t.answer("GET", "/api/v1/books/1", with: .json(#"{"id":"1","created":"2026-09-14T17:19:09Z"}"#))
        t.answer(
            "GET", "/api/v1/books/2", with: .json(#"{"id":"2","created":"2026-09-17T06:21:23.637876317Z"}"#))
        let a = makeFetch(t)
        let first = try await a.json(Answer.self, a.request("api/v1/books/1"))
        #expect(first.created == Date(timeIntervalSince1970: 1_789_406_349))
        let two = try await a.json(Answer.self, a.request("api/v1/books/2"))
        #expect(abs(two.created.timeIntervalSince1970 - 1_789_626_083.637) < 0.01)
        #expect(t.paths == ["GET /api/v1/books/1", "GET /api/v1/books/2"])
    }

    @Test("Status and transport errors arrive as source errors with a direction")
    func failure() async {
        let t = MockTransport()
        t.answer("GET", "/a", with: status(401))
        t.answer("GET", "/b", with: status(404))
        t.answer("GET", "/c", with: status(503))
        t.fail("GET", "/d", with: .timedOut)
        let a = makeFetch(t)
        let title = TitleID(source: source, id: "b")
        await #expect(throws: SourceError.signedOut(source)) { try await a.data(a.request("a")) }
        await #expect(throws: SourceError.notFound(title)) {
            try await a.data(a.request("b"), title: title)
        }
        await #expect(throws: SourceError.serverDisruption(source, status: 503)) {
            try await a.data(a.request("c"))
        }
        await #expect(throws: SourceError.unreachable(source)) { try await a.data(a.request("d")) }
    }

    @Test("A body that does not match the type is unreadable — with the field in the trace")
    func unreadable() async {
        let t = MockTransport()
        t.answer("GET", "/x", with: .json(#"{"id":"1"}"#))
        t.answer("GET", "/y", with: .json("<!doctype html>"))
        let a = makeFetch(t)
        await #expect(throws: SourceError.unreadable(source, "Field missing: created")) {
            try await a.json(Answer.self, a.request("x"))
        }
        do {
            _ = try await a.json(Answer.self, a.request("y"))
            Issue.record("HTML ist kein JSON")
        } catch let failure as SourceError {
            #expect(failure.messageKey == "error.unreadable")
        } catch {
            Issue.record("Falscher Fehlertyp: \(error)")
        }
    }

    @Test("A request without a registered response stands out")
    func unerwartet() async {
        let a = makeFetch(MockTransport())
        await #expect(throws: SourceError.unreadable(source, "Unexpected")) {
            try await a.data(a.request("nie"))
        }
    }

    @Test("Several responses to the same path come in order, the last one stays")
    func bookSeries() async throws {
        let t = MockTransport()
        t.answer("GET", "/z", with: status(401))
        t.answer("GET", "/z", with: .json("{}"))
        let a = makeFetch(t)
        await #expect(throws: SourceError.signedOut(source)) { try await a.data(a.request("z")) }
        _ = try await a.data(a.request("z"))
        _ = try await a.data(a.request("z"))
        #expect(t.requests.count == 3)
    }

    private func status(_ status: Int) -> MockTransport.Answer {
        MockTransport.Answer(status: status)
    }
}
