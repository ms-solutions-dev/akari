import Foundation
import Testing

@testable import SourcesKitMocks

@Suite("Mock book")
struct MockBookTests {

    @Test("The built EPUB is a valid ZIP with mimetype first")
    func archive() throws {
        let data = MockBook.epub(chapter: 3)
        #expect(data.count > 4_000)
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #if os(macOS)
            let target = FileManager.default.temporaryDirectory.appending(
                path: "attrappe-\(UUID().uuidString).epub")
            try data.write(to: target)
            defer { try? FileManager.default.removeItem(at: target) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-tq", target.path]
            unzip.standardOutput = Pipe()
            try unzip.run()
            unzip.waitUntilExit()
            #expect(unzip.terminationStatus == 0)
        #endif
    }

    @Test("CRC32 matches the reference value")
    func crc() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
