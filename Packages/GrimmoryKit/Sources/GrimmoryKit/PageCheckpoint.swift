import Foundation

/// The catalog pages of a full sync on disk while it runs — so that an interrupted first sync
/// (app swiped away, iOS out of patience) resumes instead of starting over.
///
/// Every page lands here the moment it arrives (about 1 MB each, 36 for 36,000 books). The next
/// full sync takes the stored pages if the catalog still has the same size and the pages are
/// young; page 0 always comes fresh, it carries the size. Once a whole extract is stored by the
/// library, the pages are no longer needed (``GrimmorySource/library(previously:progress:)``
/// clears them).
struct PageCheckpoint: Sendable {
    let folder: URL

    /// How long stored pages count — a resumed first sync, not a substitute for the full sync
    /// every six hours, which is meant to fetch changed metadata.
    static let maxAge: TimeInterval = 2 * 3600

    private struct Meta: Codable {
        let total: Int
        let pageSize: Int
        let started: Date
    }

    private var metaPath: URL { folder.appending(path: "meta.json") }
    private func path(_ page: Int) -> URL { folder.appending(path: "\(page).json") }

    /// Prepares for a sync with `total` books: keeps the pages of an interrupted sync with the
    /// same total and page size if they are young enough, otherwise starts empty.
    /// - Returns: whether stored pages may be used.
    @discardableResult
    func begin(total: Int, pageSize: Int, now: Date = Date()) -> Bool {
        if let data = try? Data(contentsOf: metaPath),
            let meta = try? JSONDecoder().decode(Meta.self, from: data),
            meta.total == total, meta.pageSize == pageSize,
            now.timeIntervalSince(meta.started) < PageCheckpoint.maxAge
        {
            return true
        }
        clear()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Meta(total: total, pageSize: pageSize, started: now)) {
            try? data.write(to: metaPath, options: .atomic)
        }
        return false
    }

    func data(_ page: Int) -> Data? {
        try? Data(contentsOf: path(page))
    }

    func store(_ data: Data, page: Int) {
        try? data.write(to: path(page), options: .atomic)
    }

    /// The numbers of the stored pages — for tests and the log.
    func stored() -> Set<Int> {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return Set(names.compactMap { $0.hasSuffix(".json") ? Int($0.dropLast(5)) : nil })
    }

    func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}
