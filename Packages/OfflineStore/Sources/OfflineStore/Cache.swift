import Foundation

/// The cache: what the app keeps invisibly and evicts itself.
///
/// With a ceiling and eviction — the storage row in the accounts sheet shows a
/// measured number, not an estimated one. What is kept (pinned, with badge) lies
/// elsewhere and does not count here.
public enum Cache {

    /// The folder the system itself may evict.
    public static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// The sum of all files below it, in bytes. Walks the tree — milliseconds for a cache
    /// of a few hundred files, do not call on the main thread if there are more.
    public static func size(in folder: URL = folder) -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard
            let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])
        else { return 0 }
        var sum: Int64 = 0
        for item in walker {
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: resourceKeys),
                values.isRegularFile == true
            else { continue }
            sum += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return sum
    }

    /// Empties the folder — the entries, not the folder itself.
    public static func clearOut(_ folder: URL = folder) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])
        for entry in contents {
            try FileManager.default.removeItem(at: entry)
        }
    }
}

extension Cache {

    public static let limitKey = "vorrat.obergrenze"
    public static let preloadAtHomeKey = "vorrat.vorabDaheim"
    /// 2 GB: about 27 volumes or 2,500 books — the cache needs no more to carry a week
    /// on the road.
    public static let limitDefault: Int64 = 2 * 1024 * 1024 * 1024

    /// The ceiling in bytes — the slider in the storage sheet, 1 to 8 GB.
    public static func limit(_ persistence: UserDefaults = .standard) -> Int64 {
        let value = persistence.object(forKey: limitKey) as? Int64
        return value.map { min(max($0, 1 << 30), 8 << 30) } ?? limitDefault
    }

    /// How much of it may be covers: half, at least 150 MB. At 2 GB that is about 30,000
    /// covers at tile size — a large library then scrolls without reloading, even through
    /// the tunnel. Before, the cap was fixed at 150 MB, about 3,000 covers. The covers
    /// live in the cache and count toward its ceiling.
    public static func coverFraction(_ limit: Int64) -> Int64 {
        max(limit / 2, 150 << 20)
    }

    public static func set(limit: Int64, _ persistence: UserDefaults = .standard) {
        persistence.set(limit, forKey: limitKey)
    }

    /// Trims the cache below the ceiling — what was unused longest first (modification
    /// time; the image loader sets it on reading). Kept items lie elsewhere and are never
    /// touched.
    public static func cleanUp(until limit: Int64, in folder: URL = folder) {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
        ]
        guard
            let walker = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])
        else { return }
        var files: [(URL, Int64, Date)] = []
        for item in walker {
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: resourceKeys),
                values.isRegularFile == true
            else { continue }
            files.append(
                (
                    url, Int64(values.totalFileAllocatedSize ?? 0),
                    values.contentModificationDate ?? .distantPast
                )
            )
        }
        var used = files.reduce(0) { $0 + $1.1 }
        guard used > limit else { return }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) where used > limit {
            try? FileManager.default.removeItem(at: url)
            used -= size
        }
    }
}
