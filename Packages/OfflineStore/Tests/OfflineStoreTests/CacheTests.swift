import Foundation
import Testing

@testable import OfflineStore

@Suite("Zwischenspeicher")
struct CacheTests {

    @Test("Measures what is in it, and empties the entries — the folder stays")
    func measureAndEmpty() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "zwischenspeicher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: "tief"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Cache.size(in: folder) == 0)
        try Data(repeating: 1, count: 10_000).write(to: folder.appending(path: "a.bin"))
        try Data(repeating: 2, count: 20_000).write(to: folder.appending(path: "tief/b.bin"))
        // Occupied blocks, not bytes: at least the content, rounded up.
        #expect(Cache.size(in: folder) >= 30_000)
        try Cache.clearOut(folder)
        #expect(Cache.size(in: folder) == 0)
        #expect(FileManager.default.fileExists(atPath: folder.path()))
    }

    @Test("A folder that does not exist measures zero")
    func missing() {
        #expect(Cache.size(in: URL(filePath: "/gibt/es/nicht")) == 0)
    }
}
