import CoreGraphics
import Foundation
import ImageIO
import SourcesKit
import SourcesKitMocks
import Testing
import UniformTypeIdentifiers

@testable import ComicReader

@Suite("Page loader")
struct PageLoaderTests {

    /// A JPEG with the desired measures - a color field, the loader needs no more.
    static func jpeg(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(target, image, nil)
        CGImageDestinationFinalize(target)
        return data as Data
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "comicleser-" + UUID().uuidString)
    }

    @Test("From the server: downscaled to the screen edge, with duration, then from disk without network")
    func networkAndDisk() async throws {
        let t = MockTransport()
        t.answer("GET", "/pages/1", with: .init(data: Self.jpeg(width: 2000, height: 3000)))
        let folder = folder()
        let lader = PageLoader(
            count: 3, address: { URL(string: "https://comics.example/pages/\($0)")! },
            headerLines: ["X-API-Key": "k"],
            transport: t, folder: folder, pixels: 600)
        let image = try #require(await lader.image(1))
        #expect(image.height == 600)
        #expect(image.width == 400)
        #expect(image.duration != nil)
        #expect(t.requests.first?.value(forHTTPHeaderField: "X-API-Key") == "k")

        // A second loader (new memory) finds the page on disk.
        let second = PageLoader(
            count: 3, address: { URL(string: "https://comics.example/pages/\($0)")! }, transport: t,
            folder: folder,
            pixels: 600)
        let again = try #require(await second.image(1))
        #expect(again.duration == nil)
        #expect(t.paths.count == 1)
        // A hit from memory of the same loader does not carry the network duration again -
        // otherwise every view that asks for the page again reported "loaded slowly".
        let hit = try #require(await lader.image(1))
        #expect(hit.duration == nil)
        #expect(hit.height == 600)
        #expect(t.paths.count == 1)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("A kept volume comes from the files - no network, no disk")
    func files() async throws {
        let folder = folder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "seite-0001")
        try Self.jpeg(width: 100, height: 150).write(to: file)
        let t = MockTransport()
        let lader = PageLoader(
            count: 1, address: { _ in URL(string: "https://comics.example/x")! }, files: [file],
            transport: t,
            folder: nil, pixels: 600)
        let image = try #require(await lader.image(1))
        #expect(image.height == 150)  // never larger than the original
        #expect(image.duration == nil)
        #expect(t.paths.isEmpty)
        #expect(await lader.image(2) == nil)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("Preloading fetches the bytes in the window onto disk without decoding")
    func preloads() async throws {
        let t = MockTransport()
        for i in 1...5 {
            t.answer("GET", "/pages/\(i)", with: .init(data: Self.jpeg(width: 50, height: 75)))
        }
        let folder = folder()
        let lader = PageLoader(
            count: 5, address: { URL(string: "https://comics.example/pages/\($0)")! }, transport: t,
            folder: folder,
            pixels: 600)
        await lader.preload(2...4)
        // Wait until the three jobs are through.
        for _ in 0..<50 where t.paths.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(Set(t.paths) == ["GET /pages/2", "GET /pages/3", "GET /pages/4"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 3)
        // The page then comes from disk - no fourth request.
        _ = await lader.image(3)
        #expect(t.paths.count == 3)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test("Memory evicts the oldest page when the limit drops")
    func limit() async throws {
        let t = MockTransport()
        for i in 1...3 {
            t.answer("GET", "/pages/\(i)", with: .init(data: Self.jpeg(width: 100, height: 100)))
        }
        // 100 x 100 x 4 = 40 kB per page; limit for two.
        let lader = PageLoader(
            count: 3, address: { URL(string: "https://comics.example/pages/\($0)")! }, transport: t,
            folder: nil,
            pixels: 100, limit: 90_000)
        _ = await lader.image(1)
        _ = await lader.image(2)
        _ = await lader.image(3)
        #expect(t.paths.count == 3)
        _ = await lader.image(1)  // dropped out, comes anew
        #expect(t.paths.count == 4)
        _ = await lader.image(3)  // still there
        #expect(t.paths.count == 4)
    }

    /// Fast swiping let every skimmed download keep running,
    /// the shown page waited 8-10 s behind them.
    @Test("If nobody waits for a page any more its download drops; if one still waits it keeps running")
    func cancelWithoutWaiters() async throws {
        let transport = MockTransport()
        transport.answer("GET", "/seite/*", with: .init(data: Self.jpeg(width: 40, height: 60)))
        transport.set(delay: .milliseconds(300))
        let lader = PageLoader(
            count: 10, address: { URL(string: "https://comics.example/seite/\($0)")! }, transport: transport,
            folder: nil, pixels: 100)

        // Alone and cancelled: no request reaches the server.
        let alone = Task { await lader.image(3) }
        try await Task.sleep(for: .milliseconds(50))
        alone.cancel()
        #expect(await alone.value == nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(transport.requests.isEmpty)

        // Two wait, one cancels: the other gets its image.
        let firstMatch = Task { await lader.image(4) }
        let second = Task { await lader.image(4) }
        try await Task.sleep(for: .milliseconds(50))
        firstMatch.cancel()
        #expect(await second.value != nil)
        #expect(transport.requests.count == 1)
    }

    /// Scrolling up in the webtoon: the shown page fetched its own download
    /// next to the already running preload - and stood behind twenty others.
    @Test("If a page is already being preloaded, showing waits for it instead of fetching twice")
    func noDoubleDownload() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = MockTransport()
        transport.answer("GET", "/seite/*", with: .init(data: Self.jpeg(width: 40, height: 60)))
        transport.set(delay: .milliseconds(200))
        let lader = PageLoader(
            count: 10, address: { URL(string: "https://comics.example/seite/\($0)")! }, transport: transport,
            folder: folder, pixels: 100)
        await lader.preload(5...5)
        #expect(await lader.image(5) != nil)
        #expect(transport.requests.count == 1)
    }

    @Test("Preloading fetches the next pages first - starting from the shown one")
    func nextFirst() async throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = MockTransport()
        transport.answer("GET", "/seite/*", with: .init(data: Self.jpeg(width: 40, height: 60)))
        let lader = PageLoader(
            count: 30, address: { URL(string: "https://comics.example/seite/\($0)")! }, transport: transport,
            folder: folder, pixels: 100)
        await lader.preload(1...23, around: 20)
        try await Task.sleep(for: .milliseconds(300))
        let first = transport.requests.prefix(3).compactMap { $0.url?.lastPathComponent }
        #expect(Set(first).isSubset(of: ["19", "20", "21", "22", "18"]))
    }

    @Test("A server error yields nil, no image out of nothing")
    func failure() async {
        let t = MockTransport()
        t.answer("GET", "/pages/1", with: .init(status: 500))
        let lader = PageLoader(
            count: 1, address: { URL(string: "https://comics.example/pages/\($0)")! }, transport: t,
            folder: nil,
            pixels: 100)
        #expect(await lader.image(1) == nil)
    }

    @Test("Webtoon strip: downscaled by width, otherwise it shrinks to a line")
    func byWidth() throws {
        let strip = PageLoaderTests.jpeg(width: 100, height: 1500)
        let edge = try #require(PageLoader.downscaled(strip, on: 50))
        #expect(edge.height == 50)
        let wide = try #require(PageLoader.downscaled(strip, on: 50, byWidth: true))
        #expect(wide.width == 50)
        #expect(wide.height == 750)
        // Narrower than the target: never larger than the original.
        let small = try #require(PageLoader.downscaled(strip, on: 400, byWidth: true))
        #expect(small.width == 100)
        #expect(small.height == 1500)
    }
}

@Suite("Reader")
struct ReaderTests {

    @Test("From a page stream; from a file nothing")
    func from() {
        let strom = ContentSource.pageStream(count: 12) { URL(string: "https://comics.example/p/\($0)")! }
        let volume = Reader.from(
            strom, id: "b", name: "Bokraisik Branbros", subline: "Band 3", headerLines: [:],
            transport: URLSession.shared,
            series: "s", serverDirection: nil, startPage: 40, keep: false, report: { _, _ in },
            requestKeep: {})
        #expect(volume?.count == 12)
        #expect(volume?.startPage == 12)  // beyond the end it is clipped
        let file = ContentSource.file(URL(string: "https://x/y.epub")!, size: nil, rangeCapable: true)
        #expect(
            Reader.from(
                file, id: "b", name: "x", subline: nil, headerLines: [:], transport: URLSession.shared,
                series: nil, serverDirection: nil, startPage: 1, keep: false, report: { _, _ in },
                requestKeep: {})
                == nil)
    }
}
