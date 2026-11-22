import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import WebdavKit

/// Against a real WebDAV folder, only with `AKARI_LEBEND=1`. Credentials from
/// `WEBDAV_URL`/`WEBDAV_USER`/`WEBDAV_PASS` in the environment, otherwise from a local credentials
/// file. Writes nothing on the server — the reading state is local and lives in a throwaway file
/// for the probe.
@Suite("Webdav live", .enabled(if: LiveProbe.wanted), .serialized)
struct WebdavLiveTests {

    /// Environment before file — the probe is started with variables.
    static func access(_ lookupKey: String) -> String? {
        ProcessInfo.processInfo.environment[lookupKey] ?? LiveProbe.access()[lookupKey]
    }

    @Test("Sign in, catalog at depth ∞, backfill, cover and page 1 via the switch, reading state local")
    func roundTrip() async throws {
        let folder = try #require(Self.access("WEBDAV_URL").flatMap(URL.init))
        let account = try await WebdavSource.signIn(
            folder: folder, username: try #require(Self.access("WEBDAV_USER")),
            password: try #require(Self.access("WEBDAV_PASS")))
        print("Webdav: folder \(account.title), identifier \(account.identifier)")
        let states = FileManager.default.temporaryDirectory.appending(
            path: "webdav-lebend-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: states) }
        let backfill = BackfillStore(file: nil)
        let q = WebdavSource(account: account, persistence: states, backfill: backfill)

        var extract = try await q.library()
        #expect(
            extract.title.count == 5, "three EPUB, one PDF, one CBZ — \(extract.title.map(\.identifier.id))")
        // The backfill runs with a time budget; through the tunnel it may still be on its way after
        // the first run — then once more, from the store.
        for _ in 0..<6 where extract.title.contains(where: { $0.kind == .manga && $0.scope == .unknown }) {
            try await Task.sleep(for: .seconds(5))
            extract = try await q.library()
        }
        let epub = try #require(extract.title.first { $0.format == "EPUB" && $0.cover != nil })
        let manga = try #require(extract.title.first { $0.kind == .manga })
        let pdf = try #require(extract.title.first { $0.format == "PDF" })
        #expect(pdf.cover == nil && pdf.kind == .book)
        let epubAddress = try #require(q.file(epub))
        let finding = try #require(backfill.finding(epubAddress))
        print(
            "Webdav: \(epub.identifier.id) → OPF name “\(finding.name ?? "—")”, authors \(finding.authors), series \(finding.bookSeries ?? "—")"
        )
        #expect(finding.name != nil && !finding.authors.isEmpty, "the OPF names title and author")

        var request = URLRequest(url: try #require(epub.cover))
        for (k, v) in q.headerLines() { request.setValue(v, forHTTPHeaderField: k) }
        let (cover, coverResponse) = try await q.gate.send(request)
        #expect(
            coverResponse.statusCode == 200 && cover.count > 1000,
            "Cover: \(coverResponse.statusCode), \(cover.count) B")
        #expect(coverResponse.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true)

        var pageBytes = 0
        if case .pageStream(let count, let page, _) = q.content(manga) {
            var pageRequest = URLRequest(url: page(1))
            for (k, v) in q.headerLines() { pageRequest.setValue(v, forHTTPHeaderField: k) }
            let (image, response) = try await q.gate.send(pageRequest)
            pageBytes = image.count
            #expect(
                response.statusCode == 200 && image.count > 1000,
                "Page 1 of \(count): \(response.statusCode), \(image.count) B")
            #expect(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("image/") == true)
        } else {
            Issue.record(
                "\(manga.identifier.id): no page stream — backfill pending or directory unreadable")
        }

        let state = ReadingState(
            position: .position(cfi: "epubcfi(/6/4)", fraction: 0.25), timestamp: Date(),
            device: "Lebendprobe")
        try await q.write(state, for: epub.identifier)
        let again = try #require(try await q.progress(epub.identifier))
        #expect(again.fraction == 0.25 && again.device == "Lebendprobe")
        try await q.forget(progressFor: epub.identifier)
        #expect(try await q.progress(epub.identifier) == nil)
        print(
            "Webdav: \(extract.title.count) titles, backfill \(backfill.count), cover \(cover.count) bytes, page 1 \(pageBytes) bytes"
        )
    }
}
