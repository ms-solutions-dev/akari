import Foundation
import Testing

@testable import SourcesKit

@Suite("Network status and source errors")
struct NetworkStatusTests {
    let komga = SourceID(provider: .komga, server: "comics.example")

    @Test("Three states, two of them carry")
    func usable() {
        #expect(NetworkStatus.reachable.usable)
        #expect(NetworkStatus.slow(mbit: 0.3).usable)
        #expect(!NetworkStatus.unreachable.usable)
    }

    @Test("In the tunnel a 700 kB page takes about 19 seconds")
    func durationInTunnel() throws {
        let seconds = try #require(NetworkStatus.slow(mbit: 0.3).duration(for: 700_000))
        #expect(abs(seconds - 18.67) < 0.01)
        let volume = try #require(NetworkStatus.slow(mbit: 0.3).duration(for: 76_000_000))
        #expect(abs(volume / 60 - 33.8) < 0.1)
    }

    @Test("At home and never reachable compute no duration")
    func noDuration() {
        #expect(NetworkStatus.reachable.duration(for: 700_000) == nil)
        #expect(NetworkStatus.unreachable.duration(for: 700_000) == nil)
        #expect(NetworkStatus.slow(mbit: 0).duration(for: 700_000) == nil)
        #expect(NetworkStatus.slow(mbit: 0.3).duration(for: 0) == nil)
    }

    @Test("A status is read the same way in all three kits")
    func statusMapping() {
        let title = TitleID(source: komga, id: "b1")
        #expect(SourceError.from(status: 200, source: komga) == nil)
        #expect(SourceError.from(status: 304, source: komga) == nil)
        #expect(SourceError.from(status: 401, source: komga) == .signedOut(komga))
        #expect(SourceError.from(status: 407, source: komga) == .signedOut(komga))
        #expect(SourceError.from(status: 403, source: komga) == .denied(komga))
        #expect(SourceError.from(status: 404, source: komga, title: title) == .notFound(title))
        #expect(SourceError.from(status: 404, source: komga) == .unreadable(komga, "404 without title"))
        #expect(SourceError.from(status: 503, source: komga) == .serverDisruption(komga, status: 503))
        #expect(SourceError.from(status: 418, source: komga) == .unreadable(komga, "Response 418"))
    }

    @Test("Every transport error means: unreachable — no \"waking up\"")
    func transportError() {
        for code in [URLError.timedOut, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed] {
            #expect(SourceError.from(URLError(code), source: komga) == .unreachable(komga))
        }
        struct Foreign: Error {}
        #expect(SourceError.from(Foreign(), source: komga) == .unreadable(komga, "Foreign"))
        #expect(SourceError.from(SourceError.signedOut(komga), source: komga) == .signedOut(komga))
    }

    @Test(
        "Every error names its source, its key and whether it makes sense to try again right away"
    )
    func direction() {
        let title = TitleID(source: komga, id: "b1")
        let all: [SourceError] = [
            .unreachable(komga), .signedOut(komga), .denied(komga), .notFound(title),
            .serverDisruption(komga, status: 500), .unreadable(komga, "x"), .notPossible(komga, "y"),
        ]
        for failure in all {
            #expect(failure.source == komga)
            #expect(failure.messageKey.hasPrefix("error."))
        }
        #expect(!SourceError.unreachable(komga).final)
        #expect(!SourceError.serverDisruption(komga, status: 502).final)
        #expect(SourceError.signedOut(komga).final)
        #expect(SourceError.denied(komga).final)
        #expect(SourceError.notFound(title).final)
        #expect(SourceError.signedOut(komga).messageKey == SourceError.denied(komga).messageKey)
    }
}
