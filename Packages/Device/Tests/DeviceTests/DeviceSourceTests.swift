import Compression
import CoreGraphics
import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Device

@Suite("Zip")
struct ZipTests {

    @Test("Write and read — stored, with an umlaut in the name")
    func roundTrip() throws {
        let data = Zip.archive([("a.txt", Data("hallo".utf8)), ("Ordner/ü.bin", Data([0, 1, 2, 255]))])
        let zip = try Zip(data: data)
        #expect(zip.entries.map(\.name) == ["a.txt", "Ordner/ü.bin"])
        #expect(try zip.content("a.txt") == Data("hallo".utf8))
        #expect(try zip.content("Ordner/ü.bin") == Data([0, 1, 2, 255]))
        #expect(throws: Zip.Failure.entryMissing("x")) { try zip.content("x") }
    }

    @Test("Deflate entries are inflated by the system")
    func deflate() throws {
        let plain = Data(String(repeating: "Akari ", count: 200).utf8)
        var packed = Data(count: plain.count + 64)
        let length = packed.withUnsafeMutableBytes { target in
            plain.withUnsafeBytes { source in
                compression_encode_buffer(
                    target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, plain.count, nil, COMPRESSION_ZLIB)
            }
        }
        packed = packed.prefix(length)
        // A hand-made archive with method 8.
        var archive = Data()
        func z<T: FixedWidthInteger>(_ w: T) {
            withUnsafeBytes(of: w.littleEndian) { archive.append(contentsOf: $0) }
        }
        let name = Data("t.txt".utf8)
        z(UInt32(0x0403_4B50)); z(UInt16(20)); z(UInt16(0)); z(UInt16(8)); z(UInt16(0)); z(UInt16(0))
        z(Zip.crc32(plain)); z(UInt32(packed.count)); z(UInt32(plain.count)); z(UInt16(name.count));
        z(UInt16(0))
        archive.append(name); archive.append(packed)
        let centralOffset = UInt32(archive.count)
        z(UInt32(0x0201_4B50)); z(UInt16(20)); z(UInt16(20)); z(UInt16(0)); z(UInt16(8)); z(UInt16(0));
        z(UInt16(0))
        z(Zip.crc32(plain)); z(UInt32(packed.count)); z(UInt32(plain.count)); z(UInt16(name.count));
        z(UInt16(0))
        z(UInt16(0)); z(UInt16(0)); z(UInt16(0)); z(UInt32(0)); z(UInt32(0)); archive.append(name)
        let centralSize = UInt32(archive.count) - centralOffset
        z(UInt32(0x0605_4B50)); z(UInt16(0)); z(UInt16(0)); z(UInt16(1)); z(UInt16(1)); z(centralSize);
        z(centralOffset); z(UInt16(0))
        let zip = try Zip(data: archive)
        #expect(try zip.content("t.txt") == plain)
        // The same Deflate entry through the range reader — directory from the tail,
        // content from the entry's range.
        let remote = try Zip.Remote(tail: archive.suffix(min(128, archive.count)), size: archive.count)
        let e = try #require(remote.entry("t.txt"))
        #expect(try remote.content(e, from: archive.subdata(in: remote.area(e))) == plain)
    }

    @Test("Range reader: directory from the tail of an EPUB, OPF and cover path from ranges")
    func remote() throws {
        let epub = MockBook.epub(name: "Die Fernprobe")
        let tail = epub.suffix(min(Zip.Remote.tail, epub.count))
        let remote = try Zip.Remote(tail: Data(tail), size: epub.count)
        #expect(remote.entries.map(\.name).contains("OEBPS/content.opf"))
        let container = try #require(remote.entry("META-INF/container.xml"))
        let area = remote.area(container)
        #expect(area.lowerBound < area.upperBound && area.upperBound <= epub.count)
        let containerData = try remote.content(container, from: epub.subdata(in: area))
        let opfPath = try #require(Opf.rootfile(containerData))
        #expect(opfPath == "OEBPS/content.opf")
        let opfEntry = try #require(remote.entry(opfPath))
        let opf = Opf(try remote.content(opfEntry, from: epub.subdata(in: remote.area(opfEntry))))
        #expect(opf.title == "Die Fernprobe" && opf.language == "de")
        #expect(opf.coverPath(opfPath: opfPath) == nil, "the mock has no cover")
        // A tail that no longer contains the directory says how much it needs.
        #expect(throws: Zip.Failure.self) { try Zip.Remote(tail: epub.suffix(30), size: epub.count) }
        do {
            _ = try Zip.Remote(tail: epub.suffix(30), size: epub.count)
        } catch Zip.Failure.tailTooShort(let needed) {
            #expect(needed > 30 && needed <= epub.count)
            let enough = try Zip.Remote(tail: epub.suffix(needed), size: epub.count)
            #expect(enough.entries.count == remote.entries.count)
        }
        // A range that ends before the data says how long it has to be.
        let tooShort = epub.subdata(in: opfEntry.offset..<(opfEntry.offset + 40))
        do {
            _ = try remote.content(opfEntry, from: tooShort)
            Issue.record("a range that is too short must fail")
        } catch Zip.Failure.rangeTooShort(let needed) {
            #expect(needed == 30 + opfEntry.headLength + opfEntry.packed)
        }
        // The entry survives storage as JSON — this is how the source remembers the position of the cover.
        let encoded = try JSONEncoder().encode(opfEntry)
        #expect(try JSONDecoder().decode(Zip.Item.self, from: encoded) == opfEntry)
    }
}

@Suite("Source on the device")
struct DeviceSourceTests {

    func fresh() throws -> DeviceSource {
        let folder = FileManager.default.temporaryDirectory.appending(path: "geraet-\(UUID().uuidString)")
        return DeviceSource(folder: folder)
    }

    static func png() -> Data {
        // 2×3 pixels so that the page is an image.
        let context = CGContext(
            data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        return FileMetadata.jpeg(context.makeImage()!)!
    }

    @Test("EPUB: title and author from the OPF, file copied, state local")
    func epub() async throws {
        let source = try fresh()
        let file = FileManager.default.temporaryDirectory.appending(path: "Probe-\(UUID().uuidString).epub")
        try MockBook.epub().write(to: file)
        let identifier = try source.importFile(file)
        let extract = try await source.library()
        #expect(extract.title.count == 1)
        let title = try #require(extract.title.first)
        #expect(title.identifier == identifier)
        #expect(title.kind == .book)
        #expect(title.name != "inhalt")
        #expect(!title.name.hasPrefix("Probe-"))
        if case .file(let address, _, _) = source.content(title) {
            #expect(address.lastPathComponent == "inhalt.epub")
            #expect(FileManager.default.fileExists(atPath: address.path))
        } else {
            Issue.record("no file content")
        }
        let state = ReadingState(
            position: .position(cfi: "epubcfi(/6/4!/4/2)", fraction: 0.4), timestamp: Date())
        try await source.write(state, for: identifier)
        #expect(try await source.progress(identifier)?.fraction == 0.4)
        try await source.forget(progressFor: identifier)
        #expect(try await source.progress(identifier) == nil)
        try source.erase(identifier)
        #expect(try await source.library().title.isEmpty)
    }

    @Test("CBZ: manga, pages unpacked in reading order, cover is the first page")
    func cbz() async throws {
        let source = try fresh()
        let image = DeviceSourceTests.png()
        let archive = Zip.archive([
            ("10.jpg", image), ("2.jpg", image), ("1.jpg", image), ("Thumbs.db", Data([1])),
        ])
        let file = FileManager.default.temporaryDirectory.appending(path: "Blawosfil Saga 01.cbz")
        try archive.write(to: file)
        let identifier = try source.importFile(file)
        let title = try await source.title(identifier)
        #expect(title.kind == .manga)
        #expect(title.name == "Blawosfil Saga 01")
        #expect(title.scope == .pages(3))
        #expect(title.cover?.lastPathComponent == "cover.jpg")
        guard case .pageStream(let count, let page, _) = source.content(title) else {
            Issue.record("no page stream"); return
        }
        #expect(count == 3)
        // 1-based as in the reader: page 1 is the cover, page 3 the last.
        #expect(page(1).lastPathComponent == "00000.jpg")
        #expect(page(3).lastPathComponent == "00002.jpg")
        let (data, response) = try await FileTransport().send(URLRequest(url: page(2)))
        #expect(response.statusCode == 200)
        #expect(data == image)
    }

    @Test("PDF: page count, title from the info dictionary, first page as cover")
    func pdf() async throws {
        let source = try fresh()
        let file = FileManager.default.temporaryDirectory.appending(path: "p-\(UUID().uuidString).pdf")
        var frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(
            file as CFURL, mediaBox: &frame,
            [kCGPDFContextTitle: "Das Probeheft", kCGPDFContextAuthor: "A. Autor"] as CFDictionary)!
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
        let identifier = try source.importFile(file)
        let title = try await source.title(identifier)
        #expect(title.name == "Das Probeheft")
        #expect(title.authors == ["A. Autor"])
        #expect(title.scope == .pages(2))
        #expect(title.cover != nil)
    }

    @Test("Package: built from a title, read back in — series, volume and cover are kept")
    func package() async throws {
        let source = try fresh()
        let epub = FileManager.default.temporaryDirectory.appending(path: "q-\(UUID().uuidString).epub")
        try MockBook.epub().write(to: epub)
        let origin = Title(
            identifier: TitleID(
                source: SourceID(provider: .grimmory, server: "buecher.example"), id: "42"),
            kind: .book, name: "Sherlock Holmes", authors: ["Arthur Conan Doyle"],
            series: SeriesReference(
                identifier: SeriesID(
                    source: SourceID(provider: .grimmory, server: "buecher.example"), id: "s"),
                name: "Sherlock Holmes", volume: 2),
            summary: "Eine Welt unter der Erde.", language: "de")
        let package = try DeviceSource.package(origin, file: epub, cover: DeviceSourceTests.png())
        let packageFile = FileManager.default.temporaryDirectory.appending(path: "Sherlock Holmes.akari")
        try package.write(to: packageFile)
        let identifier = try source.importFile(packageFile)
        let title = try await source.title(identifier)
        #expect(title.name == "Sherlock Holmes")
        #expect(title.series?.volume == 2)
        #expect(title.summary == "Eine Welt unter der Erde.")
        #expect(title.cover?.lastPathComponent == "cover.jpg")
        let extract = try await source.library()
        #expect(extract.seriesList.map(\.name) == ["Sherlock Holmes"])
        #expect(source.file(title)?.lastPathComponent == "inhalt.epub")
    }

    @Test("Unknown extension and package without metadata are rejected, nothing is left behind")
    func reject() throws {
        let source = try fresh()
        let txt = FileManager.default.temporaryDirectory.appending(path: "x.txt")
        try Data("x".utf8).write(to: txt)
        #expect(throws: DeviceSource.Failure.unknownExtension("txt")) { try source.importFile(txt) }
        let empty = FileManager.default.temporaryDirectory.appending(path: "leer.akari")
        try Zip.archive([("nichts.txt", Data())]).write(to: empty)
        #expect(throws: DeviceSource.Failure.packageWithoutMetadata) { try source.importFile(empty) }
        #expect(source.all().isEmpty)
    }
}
