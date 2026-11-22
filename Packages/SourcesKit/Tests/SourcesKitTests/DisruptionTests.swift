import Foundation
import SourcesKitMocks
import Testing

@testable import SourcesKit

/// Network speed from the fetches, the measuring transport, and mocks that play 401,
/// 502, outage and tunnel on command.
@Suite("Disruptions: network speed and mocks")
struct DisruptionTests {
    let komga = SourceID(provider: .komga, server: "comics.example")

    @Test("Two pages through the tunnel: slow with a number; at home it stays reachable")
    func tempo() {
        var tempo = NetworkSpeed()
        #expect(tempo.phase == .reachable)
        #expect(tempo.mbit == nil)
        tempo.save(bytes: 700_000, duration: 18)
        #expect(tempo.phase == .reachable, "eine Messung entscheidet nichts")
        tempo.save(bytes: 690_000, duration: 19)
        guard case .slow(let mbit) = tempo.phase else {
            Issue.record("nach zwei Messungen unter 1 Mbit/s: langsam")
            return
        }
        #expect(abs(mbit - 0.3) < 0.01)

        var atHome = NetworkSpeed()
        atHome.save(bytes: 700_000, duration: 0.1)
        atHome.save(bytes: 700_000, duration: 0.12)
        #expect(atHome.phase == .reachable)
        #expect(atHome.mbit! > 40)
    }

    @Test("Small responses measure latency, not bandwidth — they do not count")
    func smallResponses() {
        var tempo = NetworkSpeed()
        tempo.save(bytes: 4_000, duration: 3)
        tempo.save(bytes: 8_000, duration: 3)
        tempo.save(bytes: 200_000, duration: 0.001)
        #expect(tempo.mbit == nil)
    }

    @Test("Hysteresis: only above 1.5 Mbit/s is it unremarkable again; a new path forgets everything")
    func hysteresis() {
        var tempo = NetworkSpeed()
        tempo.save(bytes: 700_000, duration: 18)
        tempo.save(bytes: 700_000, duration: 18)
        #expect(tempo.phase != .reachable)
        // Six fast measurements push the slow ones out of the window.
        for _ in 0..<6 { tempo.save(bytes: 700_000, duration: 0.5) }
        #expect(tempo.phase == .reachable)
        tempo.save(bytes: 700_000, duration: 18)
        tempo.save(bytes: 700_000, duration: 18)
        tempo.save(bytes: 700_000, duration: 18)
        tempo.save(bytes: 700_000, duration: 18)
        #expect(tempo.phase != .reachable)
        tempo.forget()
        #expect(tempo.phase == .reachable)
        #expect(tempo.mbit == nil)
    }

    @Test(
        "Loaded simultaneously, the time in which something ran counts — six covers in one second are not slow"
    )
    func simultaneous() {
        var tempo = NetworkSpeed()
        // Six covers of 200 kB, all in the same second: 9.6 Mbit/s, not 1.6.
        for _ in 0..<6 { tempo.save(bytes: 200_000, startTime: 10, end: 11) }
        #expect(tempo.phase == .reachable)
        #expect(abs((tempo.mbit ?? 0) - 9.6) < 0.01)
    }

    @Test("Responses of an API (JSON) measure the server's compute time, not the line")
    func withoutJSON() async throws {
        let inner = MockTransport()
        inner.answer("GET", "/api", with: .json(String(repeating: " ", count: 20_000)))
        inner.answer(
            "GET", "/cover",
            with: .init(data: Data(repeating: 1, count: 20_000), headerLines: ["Content-Type": "image/jpeg"]))
        let measured = MeterBox()
        let transport = MeteringTransport(inner) { bytes, startTime, end in
            measured.save(bytes, end - startTime)
        }
        _ = try await transport.send(URLRequest(url: URL(string: "https://x.example/api")!))
        _ = try await transport.send(URLRequest(url: URL(string: "https://x.example/cover")!))
        #expect(measured.values.map(\.0) == [20_000], "nur das Cover")
    }

    @Test("The metering transport passes on bytes and duration and streams where the session behind it can")
    func meteringTransport() async throws {
        let inner = MockTransport()
        inner.answer("GET", "/seite", with: .init(data: Data(repeating: 1, count: 20_000)))
        let measured = MeterBox()
        let transport = MeteringTransport(inner) { bytes, startTime, end in
            measured.save(bytes, end - startTime)
        }
        let (data, response) = try await transport.send(
            URLRequest(url: URL(string: "https://x.example/seite")!))
        #expect(data.count == 20_000)
        #expect(response.statusCode == 200)
        #expect(measured.values.count == 1)
        #expect(measured.values.first?.0 == 20_000)
        #expect(transport.session(for: URLRequest(url: URL(string: "https://x.example/seite")!)) == nil)
        let withSession = MeteringTransport(URLSession.shared) { _, _, _ in }
        #expect(
            withSession.session(for: URLRequest(url: URL(string: "https://x.example/seite")!))
                === URLSession.shared)
    }

    @Test("A mock plays 401 and 502 — and healthy again")
    func mockDisruption() async throws {
        let source = MockShelf.komga()
        source.set(disruption: .signedOut(source.identifier))
        await #expect(throws: SourceError.signedOut(source.identifier)) { try await source.verify() }
        await #expect(throws: SourceError.signedOut(source.identifier)) { _ = try await source.library() }
        source.set(disruption: .serverDisruption(source.identifier, status: 502))
        await #expect(throws: SourceError.serverDisruption(source.identifier, status: 502)) {
            try await source.verify()
        }
        source.set(disruption: nil)
        try await source.verify()
        #expect(try await source.library().title.count == 3)
    }

    @Test("The mock transport fails and comes back; the delay slows every response")
    func outage() async throws {
        let transport = MockTransport()
        transport.answer("GET", "/a", with: .init(data: Data([1])))
        let request = URLRequest(url: URL(string: "https://x.example/a")!)
        transport.set(outage: .networkConnectionLost)
        await #expect(throws: URLError.self) { _ = try await transport.send(request) }
        #expect(transport.outage == .networkConnectionLost)
        transport.set(outage: nil)
        #expect(try await transport.send(request).0 == Data([1]))
        transport.set(delay: .milliseconds(150))
        let startTime = ContinuousClock.now
        _ = try await transport.send(request)
        #expect(ContinuousClock.now - startTime >= .milliseconds(140))
    }
}

/// Collects what the metering transport reports — from any thread.
private final class MeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(Int, TimeInterval)] = []
    var values: [(Int, TimeInterval)] { lock.withLock { list } }
    func save(_ bytes: Int, _ duration: TimeInterval) {
        lock.withLock { list.append((bytes, duration)) }
    }
}
