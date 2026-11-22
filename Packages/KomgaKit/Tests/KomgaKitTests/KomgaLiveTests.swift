import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import KomgaKit

/// Against a real Komga instance, only with `AKARI_LEBEND=1`.
/// Writes exactly one reading state: the one that is already there, once more — visible
/// in Komga's web UI by the read date.
@Suite("Komga live", .enabled(if: LiveProbe.wanted), .serialized)
struct KomgaLiveTests {

    @Test("Sign in, extract, cover, page, read and write reading state, sign out")
    func walkthrough() async throws {
        let z = LiveProbe.access()
        let server = try #require(z["KOMGA_URL"].flatMap(URL.init))
        let account = try await KomgaSource.signIn(
            server: server, email: try #require(z["KOMGA_USER"]), password: try #require(z["KOMGA_PASS"]),
            deviceName: "Lebendprobe \(Date().formatted(date: .numeric, time: .shortened))")
        let q = KomgaSource(account: account)
        defer { Task { try? await q.signOut() } }
        print("Komga: Rollen \(account.roles), Fähigkeiten \(account.capabilities.rawValue)")

        let extract = try await q.library()
        print(
            "Komga: \(extract.seriesList.count) Serien, \(extract.title.count) Bände, \(extract.readingStates.count) Lesestände"
        )
        #expect(extract.seriesList.count > 0)
        #expect(extract.title.count > extract.seriesList.count)

        let volume = try #require(
            extract.title.first { extract.readingStates[$0.identifier] != nil } ?? extract.title.first)
        let (coverStatus, coverType) = try await LiveProbe.header(
            try #require(volume.cover), headerLines: q.headerLines())
        #expect(coverStatus == 200 && coverType.hasPrefix("image/"), "Cover: \(coverStatus) \(coverType)")
        guard case .pageStream(let count, let page, _) = q.content(volume) else {
            Issue.record("no stream")
            return
        }
        let (pageStatus, pageType) = try await LiveProbe.header(page(1), headerLines: q.headerLines())
        #expect(
            pageStatus == 200 && pageType.hasPrefix("image/"),
            "Seite 1 von \(count): \(pageStatus) \(pageType)")

        let single = try await q.title(volume.identifier)
        #expect(single.name == volume.name)
        let previously = try await q.progress(volume.identifier)
        print("Komga: \(volume.name) — state before \(String(describing: previously?.position))")
        // One page ahead so the web UI shows it ("218 pages left"
        // instead of 219) — and exactly back after the viewing pause.
        let before = previously?.position ?? .page(1, from: count)
        guard case .page(let page, let from) = before else {
            Issue.record("Page expected")
            return
        }
        try await q.write(
            ReadingState(position: .page(page + 1, from: from), timestamp: Date(), device: "Lebendprobe"),
            for: volume.identifier)
        let after = try #require(try await q.progress(volume.identifier))
        #expect(after.position == .page(page + 1, from: from))
        #expect(after.timestamp > (previously?.timestamp ?? .distantPast))
        print("Komga: state after \(after.position), time \(after.timestamp)")
        await LiveProbe.showPause(
            "Komga: check the web UI now — page \(page + 1) of \(from)")
        try await q.write(
            ReadingState(position: before, timestamp: Date(), device: "Lebendprobe"), for: volume.identifier)
        let back = try #require(try await q.progress(volume.identifier))
        #expect(back.position == before)
        print("Komga: reset to \(back.position)")
        try await q.signOut()
    }
}
