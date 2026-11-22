import CryptoKit
import Foundation
import SourcesKit

/// The page measures of a volume on disk - next to the pages in the cache.
///
/// **Why**: until Komga's page list arrived every webtoon page was screen-high, in
/// truth about half as high. Whoever scrolled meanwhile landed somewhere
/// else after the list (p. 1170 of 1170), and the jump back to the page tore them
/// back. With the measures from last opening the heights stand at once.
struct MeasureStore {

    let file: URL

    /// The name depends on the address of the first page - as with the pages themselves the
    /// folder carries neither server nor title.
    init(folder: URL, volume: Reader) {
        let digest = SHA256.hash(data: Data(("masse:" + volume.address(1).absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        file = folder.appending(path: digest + ".masse")
    }

    func restoreFromDisk() -> [PageSize]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([PageSize].self, from: data)
    }

    func write(_ measures: [PageSize]) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(measures).write(to: file, options: .atomic)
    }
}
