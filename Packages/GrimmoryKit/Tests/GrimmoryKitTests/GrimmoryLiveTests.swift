import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import GrimmoryKit

/// Against a live server, only with `AKARI_LEBEND=1`.
/// Writes exactly one reading state: the existing one, once more.
@Suite("Grimmory live", .enabled(if: LiveProbe.wanted), .serialized)
struct GrimmoryLiveTests {

    @Test("Sign in, extract, cover, content with Range, read and write reading state")
    func roundTrip() async throws {
        let z = LiveProbe.access()
        let server = try #require(z["GRIMMORY_URL"].flatMap(URL.init))
        let account = try await GrimmorySource.signIn(
            server: server, username: try #require(z["GRIMMORY_USER"]),
            password: try #require(z["GRIMMORY_PASS"]))
        let q = GrimmorySource(account: account)
        print(
            "Grimmory: \(account.username), may fetch: \(account.mayFetch), access until \(account.access.flow)"
        )

        let extract = try await q.library()
        print(
            "Grimmory: \(extract.seriesList.count) series, \(extract.title.count) books, \(extract.readingStates.count) reading states"
        )
        #expect(extract.title.count > 100)
        #expect(extract.seriesList.count > 10)

        let book = try #require(
            extract.title.first { extract.readingStates[$0.identifier] != nil } ?? extract.title.first)
        let (coverStatus, coverType) = try await LiveProbe.header(
            try #require(book.cover), headerLines: q.headerLines())
        #expect(coverStatus == 200 && coverType.hasPrefix("image/"), "Cover: \(coverStatus) \(coverType)")
        guard case .file(let address, _, _) = q.content(book) else {
            Issue.record("no file")
            return
        }
        let (contentStatus, contentType) = try await LiveProbe.header(
            address, headerLines: q.headerLines(), area: "bytes=0-1023")
        #expect(contentStatus == 206, "Inhalt: \(contentStatus) \(contentType)")

        let single = try await q.title(book.identifier)
        #expect(single.name == book.name)
        let previously = try await q.progress(book.identifier)
        print("Grimmory: \(book.name) — state before \(String(describing: previously?.position))")
        // Grimmory shows progress in percent with one decimal: one tenth forward,
        // then exactly back — so the write is visible in the web UI.
        let old = previously?.position ?? .fraction(0)
        let oldFraction = ReadingState(position: old, timestamp: Date()).fraction
        let before: ReadingState.Position =
            if case .position(let cfi, _) = old { .position(cfi: cfi, fraction: oldFraction + 0.001) } else {
                .fraction(oldFraction + 0.001)
            }
        try await q.write(
            ReadingState(position: before, timestamp: Date(), device: "Lebendprobe"), for: book.identifier)
        let after = try #require(try await q.progress(book.identifier))
        #expect(abs(after.fraction - (oldFraction + 0.001)) < 0.0005)
        #expect(after.timestamp > (previously?.timestamp ?? .distantPast))
        print("Grimmory: state after \(after.position), Zeit \(after.timestamp)")
        await LiveProbe.showPause(
            "Grimmory: check the web UI now — \((oldFraction + 0.001) * 100) %, Status READING"
        )
        try await q.write(
            ReadingState(position: old, timestamp: Date(), device: "Lebendprobe"), for: book.identifier)
        let back = try #require(try await q.progress(book.identifier))
        #expect(abs(back.fraction - oldFraction) < 0.0005)
        let status = try await q.title(book.identifier)
        print("Grimmory: reset to \(back.position); title \(status.name)")
    }
}
