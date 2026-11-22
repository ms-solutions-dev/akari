import Foundation
import SourcesKit
import Testing

@testable import ComicReader

/// The page measures from the last opening - so the webtoon strip has the right heights
/// immediately when continuing.
@Suite("Measure store")
struct MeasureStoreTests {

    private func volume(_ id: String) -> Reader {
        Reader(
            id: id, name: "Sternenhof", subline: nil, count: 3,
            address: { URL(string: "https://comics.example/api/v1/books/\(id)/pages/\($0)")! })
    }

    @Test("Written, read on the next opening; another volume has its own")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "masse mit raum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let measures = [PageSize(width: 800, height: 1000), PageSize(width: 800, height: 12000)]
        MeasureStore(folder: folder, volume: volume("A")).write(measures)
        #expect(MeasureStore(folder: folder, volume: volume("A")).restoreFromDisk() == measures)
        #expect(MeasureStore(folder: folder, volume: volume("B")).restoreFromDisk() == nil)
    }
}
