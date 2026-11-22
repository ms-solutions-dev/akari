import CoreGraphics
import Foundation
import ImageIO
import SourcesKit
import SourcesKitMocks
import Testing
import UniformTypeIdentifiers

@testable import OfflineStore

/// The image loader against the mock transport: header lines come along, the image is
/// downsized while decoding, and the second time nobody asks the network.
@Suite("Bildlader")
struct ImageLoaderTests {

    /// A 300 × 450 PNG — the dimensions of a cover.
    private func cover() throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let surface = try #require(
            CGContext(
                data: nil, width: 300, height: 450, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        surface.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.3, alpha: 1))
        surface.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
        let image = try #require(surface.makeImage())
        let data = NSMutableData()
        let target = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, nil)
        CGImageDestinationFinalize(target)
        return data as Data
    }

    @Test(
        "Header lines come along, the image is downsized to the edge, the disk carries it next time"
    )
    func fetchAndRemember() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "bilder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let t = MockTransport()
        t.answer("GET", "/api/v1/books/1/thumbnail", with: .init(status: 200, data: try cover()))
        let address = URL(string: "https://comics.example/api/v1/books/1/thumbnail")!

        let loader = ImageLoader(folder: folder)
        let image = try #require(
            await loader.image(address, headerLines: ["X-API-Key": "geheim"], pixels: 150, transport: t))
        #expect(image.height == 150 && image.width == 100, "the longer edge is the measure")
        #expect(t.requests[0].value(forHTTPHeaderField: "X-API-Key") == "geheim")
        #expect(await loader.used() > 0)

        // Second loader, same folder: disk instead of network.
        let second = ImageLoader(folder: folder)
        _ = await second.image(address, headerLines: [:], pixels: 150, transport: t)
        #expect(t.requests.count == 1)
        // And in the same loader from memory.
        _ = await loader.image(address, headerLines: [:], pixels: 150, transport: t)
        #expect(t.requests.count == 1)
    }

    @Test("A 404 is no image, and without a disk nothing stays")
    func missing() async throws {
        let t = MockTransport()
        t.answer("GET", "/api/v1/books/9/thumbnail", with: .init(status: 404))
        let loader = ImageLoader(folder: nil)
        let image = await loader.image(
            URL(string: "https://comics.example/api/v1/books/9/thumbnail")!, headerLines: [:], pixels: 150,
            transport: t)
        #expect(image == nil)
        #expect(await loader.used() == 0)
    }

    @Test("The store evicts what has gone unused longest")
    func storage() async throws {
        let image = try #require(ImageLoader.downscaled(try cover(), on: 100))
        let cost = image.height * image.bytesPerRow
        let storage = ImageStore(limit: cost * 2 + 1)
        storage.create(image, below: "a")
        storage.create(image, below: "b")
        _ = storage.image(to: "a")
        storage.create(image, below: "c")
        #expect(storage.image(to: "b") == nil, "b was unused longest")
        #expect(storage.image(to: "a") != nil)
        #expect(storage.used == cost * 2)
    }

    @Test("Saved returns immediately — the exact size or the largest other version")
    func saved() async throws {
        let small = try #require(ImageLoader.downscaled(try cover(), on: 100))
        let large = try #require(ImageLoader.downscaled(try cover(), on: 200))
        let storage = ImageStore()
        let loader = ImageLoader(storage: storage, folder: nil)
        let address = URL(string: "https://comics.example/api/v1/books/1/thumbnail")!
        #expect(loader.saved(address, pixels: 100) == nil)
        storage.create(small, below: "\(address.absoluteString)|100")
        storage.create(large, below: "\(address.absoluteString)|200")
        #expect(loader.saved(address, pixels: 100) === small)
        #expect(loader.saved(address, pixels: 300) === large, "the largest other version")
        #expect(loader.saved(URL(string: "https://comics.example/x")!, pixels: 100) == nil)
    }
}
