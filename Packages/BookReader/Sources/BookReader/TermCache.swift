import CoreGraphics
import Foundation

/// Glossary, index and map names per book, computed once and stored. When the book is opened
/// again, reading chapters, finding the glossary, counting and text recognition are skipped -
/// map names are tappable right away, not only from the next chapter on.
///
/// The key depends on file, size and modification date: a new version of the book recomputes.
/// ``rules`` is raised on every change to glossary, kind or map rules, otherwise
/// a stored book would still show the old state. Lives in the caches - may disappear at any time.
struct TermCache: Codable, Sendable {
    static let rules = 3

    struct Card: Codable, Sendable {
        /// Path of the image in the EPUB (``BookCard/name``) - the reader re-reads the image data.
        let path: String
        let places: [String: CGRect]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case path = "pfad"
            case places = "orte"
        }
    }

    let rules: Int
    let glossary: Glossary?
    /// The chapters of the ``TermIndex`` - `nil` without a glossary.
    let chapterIndex: [TermIndex.Chapter]?
    let cards: [Card]

    static func load(for file: URL) -> TermCache? {
        guard let place = place(for: file), let data = try? Data(contentsOf: place),
            let persistence = try? JSONDecoder().decode(TermCache.self, from: data),
            persistence.rules == rules
        else { return nil }
        return persistence
    }

    func write(for file: URL) {
        guard let place = TermCache.place(for: file), let data = try? JSONEncoder().encode(self) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: place, options: .atomic)
    }

    /// `Caches/Begriffe/<name>-<size>-<modified>.json` - without a readable file there is no place.
    static func place(for file: URL) -> URL? {
        // Read fresh: a URL remembers size and date, a newly loaded book would look old.
        var file = file
        file.removeAllCachedResourceValues()
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
            let size = values.fileSize, let changed = values.contentModificationDate,
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let name = file.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber }
            .prefix(40)
        return caches.appending(path: "Begriffe")
            .appending(path: "\(name)-\(size)-\(Int(changed.timeIntervalSince1970)).json")
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case rules = "regeln"
        case glossary = "glossar"
        case chapterIndex = "verzeichnis"
        case cards = "karten"
    }
}
