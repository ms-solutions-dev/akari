import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import AudiobookshelfKit

/// Against a real Audiobookshelf instance, only with `AKARI_LEBEND=1`.
///
/// **Audiobookshelf only stores what changes** (measured: writing the same state
/// again leaves `lastUpdate` untouched). So the state goes one second ahead and
/// then back to the old value — two writes, and in the end what was there before is there.
@Suite("Audiobookshelf live", .enabled(if: LiveProbe.wanted), .serialized)
struct AudiobookshelfLiveTests {

    @Test("Sign in, extract, cover, chapters, read and write reading state")
    func walkthrough() async throws {
        let z = LiveProbe.access()
        let server = try #require(z["ABS_URL"].flatMap(URL.init))
        let account = try await AudiobookshelfSource.signIn(
            server: server, username: try #require(z["ABS_USER"]), password: try #require(z["ABS_PASS"]))
        let q = AudiobookshelfSource(account: account)

        let extract = try await q.library()
        print(
            "Audiobookshelf: \(extract.seriesList.count) Serien, \(extract.title.count) Titel, \(extract.readingStates.count) Lesestände"
        )
        #expect(extract.title.count > 0)

        let title = try #require(
            extract.title.first { extract.readingStates[$0.identifier] != nil } ?? extract.title.first)
        let (coverStatus, coverType) = try await LiveProbe.header(
            try #require(title.cover), headerLines: q.headerLines())
        #expect(coverStatus == 200 && coverType.hasPrefix("image/"), "Cover: \(coverStatus) \(coverType)")
        let volume = try await q.audioManifest(title.identifier)
        #expect(!volume.chapter.isEmpty && !volume.tracks.isEmpty)

        let previously = try await q.progress(title.identifier)
        print("Audiobookshelf: \(title.name) — state before \(String(describing: previously?.position))")
        guard case .duration(let duration) = title.scope else {
            Issue.record("no duration")
            return
        }
        // Audiobookshelf only stores what changes (measured: writing the same state
        // again leaves `lastUpdate` untouched). So one second ahead — and afterwards exactly
        // back to the old value.
        let before: ReadingState.Position = previously?.position ?? .second(0, from: duration)
        guard case .second(let s, let from) = before else {
            Issue.record("Seconds expected")
            return
        }
        try await q.write(
            ReadingState(position: .second(s + 1, from: from), timestamp: Date(), device: "Lebendprobe"),
            for: title.identifier)
        let after = try #require(try await q.progress(title.identifier))
        #expect(after.timestamp > (previously?.timestamp ?? .distantPast))
        guard case .second(let s2, _) = after.position else {
            Issue.record("Seconds expected")
            return
        }
        #expect(abs(s2 - (s + 1)) < 0.01)
        print("Audiobookshelf: state after \(after.position), time \(after.timestamp)")
        await LiveProbe.showPause(
            "Audiobookshelf: check the web UI now — \(Int(s + 1)) s")
        try await q.write(
            ReadingState(position: before, timestamp: Date(), device: "Lebendprobe"), for: title.identifier)
        let back = try #require(try await q.progress(title.identifier))
        #expect(back.position == before)
        print("Audiobookshelf: reset to \(back.position)")
    }
}
