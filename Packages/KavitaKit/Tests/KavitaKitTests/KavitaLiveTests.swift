import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import KavitaKit

/// Against a real Kavita, only with `AKARI_LEBEND=1` and
/// `KAVITA_URL/USER/PASS` in the environment. Creates an auth key and deletes it
/// at the end; writes exactly one reading state — one page ahead and, after the
/// viewing pause, exactly back.
@Suite("Kavita live", .enabled(if: LiveProbe.wanted), .serialized)
struct KavitaLiveTests {

    @Test("Sign in, extract, cover, page, read and write reading state, sign out")
    func walkthrough() async throws {
        let z = LiveProbe.access()
        let server = try #require(z["KAVITA_URL"].flatMap(URL.init))
        let account = try await KavitaSource.signIn(
            server: server, username: try #require(z["KAVITA_USER"]),
            password: try #require(z["KAVITA_PASS"]),
            deviceName: "Lebendprobe")
        let q = KavitaSource(account: account)
        defer { Task { try? await q.signOut() } }
        print("Kavita: roles \(account.roles), own key \(account.keyId != nil)")
        try await q.verify()

        let extract = try await q.library()
        print(
            "Kavita: \(extract.seriesList.count) Serien, \(extract.title.count) Titel, \(extract.readingStates.count) Lesestände"
        )
        #expect(extract.seriesList.count > 0)

        let volume = try #require(extract.title.first { $0.kind == .manga } ?? extract.title.first)
        let (coverStatus, coverType) = try await LiveProbe.header(
            try #require(volume.cover), headerLines: q.headerLines())
        #expect(coverStatus == 200 && coverType.hasPrefix("image/"), "Cover: \(coverStatus) \(coverType)")
        if case .pageStream(let count, let page, _) = q.content(volume) {
            let (status, type) = try await LiveProbe.header(page(1), headerLines: q.headerLines())
            #expect(status == 200 && type.hasPrefix("image/"), "Seite 1 von \(count): \(status) \(type)")
        }

        let single = try await q.title(volume.identifier)
        #expect(single.name == volume.name)
        let previously = try await q.progress(volume.identifier)
        let from = if case .pages(let n) = volume.scope { n } else { 1 }
        let before = previously?.position ?? .page(1, from: from)
        guard case .page(let page, _) = before else {
            Issue.record("Page expected")
            return
        }
        try await q.write(
            ReadingState(position: .page(page + 1, from: from), timestamp: Date()), for: volume.identifier)
        let after = try #require(try await q.progress(volume.identifier))
        #expect(after.position == .page(page + 1, from: from))
        await LiveProbe.showPause(
            "Kavita: check the web UI now — page \(page + 1) of \(from)")
        if previously == nil {
            try await q.forget(progressFor: volume.identifier)
            #expect(try await q.progress(volume.identifier) == nil)
        } else {
            try await q.write(ReadingState(position: before, timestamp: Date()), for: volume.identifier)
            #expect(try await q.progress(volume.identifier)?.position == before)
        }
        try await q.signOut()
    }
}
