import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import OfflineStore

/// Keeping against the mocks: a file, a page stream, releasing, and what remains
/// after a cancellation.
@Suite("Vorratsdienst")
@MainActor
struct StockServiceTests {

    private func persistence() -> KeepStore {
        KeepStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "behalten-\(UUID().uuidString)"))
    }

    /// Waits until the entry is no longer running — two seconds at most.
    private func waitUntilDone(_ service: StockService, _ identifier: TitleID) async {
        for _ in 0..<200 {
            if let e = service.entry(identifier), case .ongoing = e.state {
                try? await Task.sleep(for: .milliseconds(10))
            } else {
                return
            }
        }
    }

    @Test("A book as a file: lies finished, with size; releasing removes it")
    func file() async throws {
        let persistence = persistence()
        defer { try? FileManager.default.removeItem(at: persistence.folder) }
        let source = MockShelf.grimmoryReadOnly()
        let book = try await source.library().title[2]
        let t = MockTransport()
        let content = Data(repeating: 7, count: 300_000)
        t.answer(
            "GET", "/api/v1/books/\(book.identifier.id)/content", with: .init(status: 200, data: content))
        let service = StockService(persistence: persistence)
        service.requestKeep(book, source: source, transport: t)
        #expect(service.entry(book.identifier) != nil)
        await waitUntilDone(service, book.identifier)
        let e = try #require(service.entry(book.identifier))
        #expect(e.done)
        #expect(e.size == 300_000)
        #expect(service.completed == [book.identifier])
        let files = try #require(service.files(book.identifier))
        #expect(files.count == 1)
        #expect(try Data(contentsOf: files[0]).count == 300_000)
        #expect(
            t.requests.filter { !($0.url?.path().contains("/covers/") ?? false) }[0].value(
                forHTTPHeaderField: "X-Attrappe") == source.identifier.description)
        // A second service reads the directory from disk.
        #expect(StockService(persistence: persistence).completed == [book.identifier])
        service.release(book.identifier)
        #expect(service.entry(book.identifier) == nil)
        #expect(!FileManager.default.fileExists(atPath: files[0].path()))
    }

    @Test("A volume as a page stream: one file per page, progress per page")
    func pages() async throws {
        let persistence = persistence()
        defer { try? FileManager.default.removeItem(at: persistence.folder) }
        let source = MockShelf.komga()
        let volume = try await source.library().title[0]
        guard case .pageStream(let count, _, _) = source.content(volume) else {
            Issue.record("page stream expected")
            return
        }
        let t = MockTransport()
        for i in 1...count {
            t.answer(
                "GET", "/api/v1/books/\(volume.identifier.id)/pages/\(i)",
                with: .init(status: 200, data: Data(repeating: 1, count: 1_000)))
        }
        let service = StockService(persistence: persistence)
        service.requestKeep(volume, source: source, transport: t)
        await waitUntilDone(service, volume.identifier)
        let e = try #require(service.entry(volume.identifier))
        #expect(e.done)
        #expect(e.files.count == count)
        #expect(e.size == Int64(count * 1_000))
        #expect(service.sum == e.size)
    }

    @Test("If the server fails, the entry stays failed — and nothing counts as kept")
    func disruption() async throws {
        let persistence = persistence()
        defer { try? FileManager.default.removeItem(at: persistence.folder) }
        let source = MockShelf.grimmoryReadOnly()
        let book = try await source.library().title[2]
        let t = MockTransport()
        t.answer("GET", "/api/v1/books/\(book.identifier.id)/content", with: .init(status: 500, data: Data()))
        let service = StockService(persistence: persistence)
        service.requestKeep(book, source: source, transport: t)
        await waitUntilDone(service, book.identifier)
        guard case .disrupted = service.entry(book.identifier)?.state else {
            Issue.record("failed expected")
            return
        }
        #expect(service.completed.isEmpty)
        #expect(service.files(book.identifier) == nil)
    }

    /// A short volume with three tracks — the mock has 634, which would be too much disk
    /// for a test.
    private func volume(_ title: Title, tracks: Int = 3, size: Int64? = 1_000) -> AudioManifest {
        let base = URL(string: "https://hoerbuch.example")!
        return AudioManifest(
            tracks: (0..<tracks).map { i in
                AudioTrack(
                    address: base.appending(path: "api/items/\(title.identifier.id)/file/\(i + 1)"),
                    startTime: Double(i) * 60, duration: 60, size: size, fileExtension: "mp3")
            },
            chapter: [
                Chapter(name: "Eins", startTime: 0, end: 90), Chapter(name: "Zwei", startTime: 90, end: 180),
            ])
    }

    @Test("An audiobook: one file per track in order, the manifest next to them, playable locally")
    func audiobook() async throws {
        let persistence = persistence()
        defer { try? FileManager.default.removeItem(at: persistence.folder) }
        let source = MockShelf.audiobookshelf()
        let title = try await source.library().title[0]
        let t = MockTransport()
        for i in 1...3 {
            t.answer(
                "GET", "/api/items/\(title.identifier.id)/file/\(i)",
                with: .init(status: 200, data: Data(repeating: UInt8(i), count: 1_000)))
        }
        let service = StockService(persistence: persistence)
        service.requestKeep(title, source: source, transport: t, audioManifest: volume(title))
        await waitUntilDone(service, title.identifier)
        let e = try #require(service.entry(title.identifier))
        #expect(e.done)
        #expect(e.files == ["spur-0001.mp3", "spur-0002.mp3", "spur-0003.mp3"])
        #expect(e.size == 3_000)
        #expect(
            t.paths.filter { !$0.contains("/covers/") }.map { $0.split(separator: "/").last! } == [
                "1", "2", "3",
            ])
        #expect(
            t.requests.filter { !($0.url?.path().contains("/covers/") ?? false) }[0].value(
                forHTTPHeaderField: "Authorization") == nil)
        #expect(
            t.requests.filter { !($0.url?.path().contains("/covers/") ?? false) }[0].value(
                forHTTPHeaderField: "X-Attrappe") == source.identifier.description)
        let local = try #require(service.audioManifest(title.identifier))
        #expect(local.local)
        #expect(local.tracks.map(\.startTime) == [0, 60, 120])
        #expect(local.tracks[1].address.lastPathComponent == "spur-0002.mp3")
        #expect(local.chapter.count == 2)
        #expect(try Data(contentsOf: local.tracks[2].address) == Data(repeating: 3, count: 1_000))
        // A second service finds the manifest on disk again.
        #expect(StockService(persistence: persistence).audioManifest(title.identifier)?.tracks.count == 3)
        service.release(title.identifier)
        #expect(service.audioManifest(title.identifier) == nil)
        #expect(!FileManager.default.fileExists(atPath: local.tracks[0].address.path()))
    }

    @Test("Resuming: finished tracks stay, a started one continues with Range")
    func audiobookResume() async throws {
        let persistence = persistence()
        defer { try? FileManager.default.removeItem(at: persistence.folder) }
        let source = MockShelf.audiobookshelf()
        let title = try await source.library().title[1]
        let folder = persistence.folder(for: title.identifier)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000).write(to: folder.appending(path: "spur-0001.mp3"))
        try Data(repeating: 2, count: 400).write(to: folder.appending(path: "spur-0002.mp3.teil"))
        let t = MockTransport()
        for i in 2...3 {
            t.answer(
                "GET", "/api/items/\(title.identifier.id)/file/\(i)",
                with: .init(status: 200, data: Data(repeating: UInt8(i), count: 1_000)))
        }
        let service = StockService(persistence: persistence)
        service.requestKeep(title, source: source, transport: t, audioManifest: volume(title))
        await waitUntilDone(service, title.identifier)
        let e = try #require(service.entry(title.identifier))
        #expect(e.done)
        #expect(e.files.count == 3)
        #expect(
            t.paths.filter { !$0.contains("/covers/") }.map { $0.split(separator: "/").last! } == ["2", "3"])
        #expect(
            t.requests.filter { !($0.url?.path().contains("/covers/") ?? false) }[0].value(
                forHTTPHeaderField: "Range") == "bytes=400-")
        #expect(
            t.requests.filter { !($0.url?.path().contains("/covers/") ?? false) }[1].value(
                forHTTPHeaderField: "Range") == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "spur-0002.mp3.teil").path()))
    }

    @Test(
        "If a track fails, the audiobook stays failed — the tracks before it are left for the next attempt")
    func audiobookDisruption() async throws {
        let persistence = persistence()
        defer { try? FileManager.default.removeItem(at: persistence.folder) }
        let source = MockShelf.audiobookshelf()
        let title = try await source.library().title[2]
        let t = MockTransport()
        t.answer(
            "GET", "/api/items/\(title.identifier.id)/file/1",
            with: .init(status: 200, data: Data(repeating: 1, count: 1_000)))
        t.answer("GET", "/api/items/\(title.identifier.id)/file/2", with: .init(status: 500, data: Data()))
        let service = StockService(persistence: persistence)
        service.requestKeep(title, source: source, transport: t, audioManifest: volume(title))
        await waitUntilDone(service, title.identifier)
        guard case .disrupted = service.entry(title.identifier)?.state else {
            Issue.record("failed expected")
            return
        }
        // Measured on disk (blocks, plus the manifest) — at least the first track.
        #expect((service.entry(title.identifier)?.size ?? 0) >= 1_000)
        #expect(service.audioManifest(title.identifier) == nil)
        #expect(service.completed.isEmpty)
    }
}

@Suite("Hoerbuchvorrat")
struct AudiobookStockTests {

    private func volume(_ sizes: [Int64?], fileExtension: String? = "mp3") -> AudioManifest {
        AudioManifest(
            tracks: sizes.enumerated().map { i, g in
                AudioTrack(
                    address: URL(string: "https://hoerbuch.example/api/items/x/file/\(i)")!,
                    startTime: Double(i) * 10,
                    duration: 10, size: g, fileExtension: fileExtension)
            }, chapter: [])
    }

    @Test("File names: four digits in track order, extension from the server or from the address")
    func filenames() {
        #expect(
            AudiobookStock.filenames(volume([1, 2, 3])) == [
                "spur-0001.mp3", "spur-0002.mp3", "spur-0003.mp3",
            ])
        #expect(AudiobookStock.filenames(volume([1], fileExtension: nil)) == ["spur-0001"])
        let withExtension = AudioManifest(
            tracks: [AudioTrack(address: URL(string: "https://x/a/b.m4b")!, startTime: 0, duration: 1)],
            chapter: [])
        #expect(AudiobookStock.filenames(withExtension) == ["spur-0001.m4b"])
    }

    @Test("The sum: all sizes or none")
    func sum() {
        #expect(volume([100, 200, 300]).size == 600)
        #expect(volume([100, nil, 300]).size == nil)
        #expect(volume([]).size == nil)
    }

    @Test("The fraction: by bytes when the sum is known, otherwise by tracks; never 100 before the end")
    func fraction() {
        #expect(AudiobookStock.fraction(bytes: 500, total: 1_000, track: 0, from: 4) == 0.5)
        #expect(AudiobookStock.fraction(bytes: 1_000, total: 1_000, track: 4, from: 4) == 0.99)
        #expect(AudiobookStock.fraction(bytes: 500, total: nil, track: 1, from: 4) == 0.25)
        #expect(AudiobookStock.fraction(bytes: 500, total: nil, track: 4, from: 4) == 0.99)
    }

    @Test("Local: the same locations on the files; the count must match")
    func local() throws {
        let b = volume([1, 2])
        let files = [URL(filePath: "/tmp/a/spur-0001.mp3"), URL(filePath: "/tmp/a/spur-0002.mp3")]
        let local = try #require(AudiobookStock.local(b, files: files))
        #expect(local.local)
        #expect(!b.local)
        #expect(local.tracks.map(\.address) == files)
        #expect(local.tracks.map(\.startTime) == [0, 10])
        #expect(local.duration == b.duration)
        #expect(AudiobookStock.local(b, files: [files[0]]) == nil)
        #expect(AudiobookStock.local(volume([]), files: []) == nil)
    }
}

@Suite("Cache · ceiling")
struct CacheCeilingTests {

    @Test("Evicts the oldest first until the limit holds; the default is 2 GB, the slider 1–8")
    func evict() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "zs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (i, name) in ["alt", "mittel", "neu"].enumerated() {
            let url = folder.appending(path: name)
            try Data(repeating: 0, count: 100_000).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1_000 + i))], ofItemAtPath: url.path)
        }
        Cache.cleanUp(until: 250_000, in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "alt").path()))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "neu").path()))
        let name = "obergrenze-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        #expect(Cache.limit(defaults) == 2 << 30)
        Cache.set(limit: 20 << 30, defaults)
        #expect(Cache.limit(defaults) == 8 << 30)
    }
}
