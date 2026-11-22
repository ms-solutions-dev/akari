import Bedrock
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SourcesKit
import Synchronization
import UniformTypeIdentifiers

/// Fetches a cover, downsizes it while decoding and remembers it — in memory and on
/// disk, below the cache.
///
/// **Three tiers in order of cost:** memory (free), disk (one file access), network —
/// through the tunnel at 0.3 Mbit/s one second per cover. Without the disk every
/// launch would be a rebuild, and the start page would have wasted its two seconds.
///
/// **Downsized while decoding, not after.** `ImageIO` builds the image at target size
/// right away; a full-size Komga cover takes megabytes unpacked, kilobytes at tile
/// size — and a grid shows thirty of them.
///
/// **The transport is the source's**, with its header lines: Komga wants the key,
/// Grimmory and Audiobookshelf the token, and the certificate guard sits in the
/// transport. The loader knows nothing of servers — it gets an address and header
/// lines and returns an image.
public actor ImageLoader {

    public static let shared = ImageLoader()

    private let storage: ImageStore
    private let folder: URL?
    private let limit: Int
    private var cleanedUp = false
    /// What is currently in flight — a second caller attaches instead of sending the
    /// same request through the tunnel again.
    private var ongoing: [String: Task<CGImage?, Never>] = [:]

    /// - Parameters:
    ///   - folder: where the downsized images live — by default below the cache, `nil`
    ///     turns the disk off (tests).
    ///   - limit: how many bytes at most stay on disk; 150 MB is about 3,000 covers at
    ///     tile size — more than the shelf has.
    public init(
        storage: ImageStore = ImageStore(),
        folder: URL? = Cache.folder.appending(path: "bilder"),
        limit: Int = 150 * 1024 * 1024
    ) {
        self.storage = storage
        self.folder = folder
        self.limit = limit
    }

    /// The image at the requested edge length — or `nil` if it does not arrive.
    ///
    /// - Parameters:
    ///   - address: the cover
    ///   - headerLines: what the source attaches to every request (``Source/headerLines()``)
    ///   - pixels: the **longer** edge in pixels
    ///   - transport: the source's session, with certificate guard
    public func image(
        _ address: URL, headerLines: [String: String], pixels: Int, transport: any Transport
    ) async -> CGImage? {
        let lookupKey = "\(address.absoluteString)|\(pixels)"
        if let saved = storage.image(to: lookupKey) { return saved }
        if let ongoing = ongoing[lookupKey] { return await ongoing.value }
        let task = Task<CGImage?, Never> {
            await fetch(
                address, headerLines: headerLines, pixels: pixels, lookupKey: lookupKey,
                transport: transport)
        }
        ongoing[lookupKey] = task
        let image = await task.value
        ongoing[lookupKey] = nil
        return image
    }

    /// What is already in memory, without waiting — so a newly appearing view shows its
    /// cover in the first frame instead of the placeholder.
    ///
    /// If the requested size is not there but another version of the same address is, the
    /// largest of them is returned: the tile on Start is 560 px, the detail wants 800 px —
    /// a briefly blurry cover while zooming is better than a color block. The right size
    /// is fetched afterwards by ``image(_:headerLines:pixels:transport:)``.
    public nonisolated func saved(_ address: URL, pixels: Int) -> CGImage? {
        storage.image(to: "\(address.absoluteString)|\(pixels)")
            ?? storage.largest(withPrefix: "\(address.absoluteString)|")
    }

    private func fetch(
        _ address: URL, headerLines: [String: String], pixels: Int, lookupKey: String,
        transport: any Transport
    ) async -> CGImage? {
        // A cover on the device (data package of a kept title): read directly. The source's
        // transport knows no files and expects an HTTP response.
        if address.isFileURL {
            let image = await Task.detached(priority: .userInitiated) {
                (try? Data(contentsOf: address)).flatMap { ImageLoader.downscaled($0, on: pixels) }
            }.value
            if let image { storage.create(image, below: lookupKey) }
            return image
        }
        // Off the actor: otherwise the fifteen covers of the start page queue up at launch
        // instead of coming from disk at the same time.
        let path = path(lookupKey)
        if let path,
            let stored = await Task.detached(
                priority: .userInitiated, operation: { ImageLoader.fromDisk(path) }
            ).value
        {
            storage.create(stored, below: lookupKey)
            return stored
        }
        var request = URLRequest(url: address)
        for (name, value) in headerLines { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                Diagnostics.network.error("Cover request returned \(response.statusCode, privacy: .public)")
                return nil
            }
            guard let image = ImageLoader.downscaled(data, on: pixels) else {
                Diagnostics.network.error(
                    "Cover could not be read (\(data.count, privacy: .public) bytes)")
                return nil
            }
            storage.create(image, below: lookupKey)
            toDisk(image, lookupKey)
            return image
        } catch is CancellationError {
            // The normal case while scrolling, not an error — whoever records it fills the log
            // with what went well.
            return nil
        } catch {
            Diagnostics.network.error("Cover not fetched: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Disk

    /// How much lies on disk — the storage row counts the cache entirely anyway; this one
    /// is for the tests.
    public func used() -> Int {
        ImageLoader.files(folder).reduce(0) { $0 + $1.size }
    }

    /// How much the covers occupy on disk — counted off the actor, for the storage row
    /// "of which covers".
    public func size() async -> Int {
        let folder = folder
        return await Task.detached(priority: .utility) {
            ImageLoader.files(folder).reduce(0) { $0 + $1.size }
        }.value
    }

    public func clearOut() async {
        storage.clearOut()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Trims back to the ceiling once per program run — the longest unused first. Not on
    /// every store: walking the folder takes noticeable time with a thousand files.
    ///
    /// The directory work runs off the actor — at launch the covers of the start page
    /// fetch their images through it right now.
    ///
    /// - Parameter until: the ceiling for this run — the covers' share of the storage
    ///   setting (``Cache/coverFraction(_:)``); without it the fixed one from `init`.
    public func cleanUpOnce(until ceiling: Int? = nil) async {
        guard !cleanedUp else { return }
        cleanedUp = true
        let folder = folder
        let limit = ceiling ?? limit
        await Task.detached(priority: .utility) {
            ImageLoader.cleanUp(folder, until: limit)
        }.value
    }

    private nonisolated static func cleanUp(_ folder: URL?, until limit: Int) {
        var present = files(folder)
        var used = present.reduce(0) { $0 + $1.size }
        guard used > limit else { return }
        present.sort { $0.recently < $1.recently }
        for file in present where used > limit {
            try? FileManager.default.removeItem(at: file.path)
            used -= file.size
        }
    }

    private struct DiskFile: Sendable {
        let path: URL
        let size: Int
        let recently: Date
    }

    private nonisolated static func files(_ folder: URL?) -> [DiskFile] {
        guard let folder,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return [] }
        return entries.map { path in
            let values = try? path.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return DiskFile(
                path: path, size: values?.fileSize ?? 0,
                recently: values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Decoded immediately (`ShouldCacheImmediately`): otherwise the JPEG decodes only on
    /// first draw — on the main thread, in the middle of scrolling.
    private nonisolated static func fromDisk(_ path: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        // The access time is the basis for eviction: what is used stays.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return image
    }

    private func toDisk(_ image: CGImage, _ lookupKey: String) {
        guard let folder, let path = path(lookupKey) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard
            let target = CGImageDestinationCreateWithURL(
                path as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        // 0.85: above that the file grows faster than the quality, below it a cover with
        // color blocks shows edges.
        CGImageDestinationAddImage(
            target, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(target)
    }

    /// A digest of the address, without extension — the folder should not carry the
    /// server's name.
    private nonisolated func path(_ lookupKey: String) -> URL? {
        guard let folder else { return nil }
        let digest = SHA256.hash(data: Data(lookupKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: digest)
    }

    /// Writes an image as JPEG — the cover in the data package of a kept title.
    nonisolated static func writeJPEG(_ image: CGImage, to path: URL) -> Bool {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard
            let target = CGImageDestinationCreateWithURL(
                path as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(
            target, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(target)
    }

    /// Builds the image at target size right away.
    nonisolated static func downscaled(_ data: Data, on pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let presets: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, presets as CFDictionary)
    }
}

/// The in-memory image store — evicts what has gone unused longest, and shrinks on
/// demand on a memory warning.
///
/// Not an `NSCache`: it evicts at its own discretion and does not say when. Here it
/// should be possible to read what lies and what fell.
///
/// **A lock instead of an actor**: A cover already in memory must be there in the
/// first frame. Through an actor it arrives at the earliest one turn later — that is
/// how long the colored placeholder stood there ("orange frame" on Start). Every
/// access is a dictionary lookup, the lock is never held for long.
public final class ImageStore: Sendable {

    private struct CachedImage {
        let image: CGImage
        let cost: Int
        var recently: UInt64
    }

    private struct Status {
        var slots: [String: CachedImage] = [:]
        /// The keys per address (everything up to and including "|") — so
        /// ``largest(withPrefix:)`` does not search all keys on every cover pass.
        var byPrefix: [Substring: Set<String>] = [:]
        var clock: UInt64 = 0
        var used = 0

        mutating func remove(_ lookupKey: String) {
            guard let previous = slots.removeValue(forKey: lookupKey) else { return }
            used -= previous.cost
            let p = ImageStore.prefix(lookupKey)
            byPrefix[p]?.remove(lookupKey)
            if byPrefix[p]?.isEmpty == true { byPrefix[p] = nil }
        }
    }

    static func prefix(_ lookupKey: String) -> Substring {
        guard let strich = lookupKey.lastIndex(of: "|") else { return Substring(lookupKey) }
        return lookupKey[...strich]
    }

    private let state = Mutex(Status())
    private let limit: Int

    /// - Parameter limit: bytes in memory — 48 MB is about 400 covers at tile size, two
    ///   screens full in each direction.
    public init(limit: Int = 48 * 1024 * 1024) {
        self.limit = limit
    }

    public var used: Int { state.withLock { $0.used } }

    public func image(to lookupKey: String) -> CGImage? {
        state.withLock { s in
            guard var slot = s.slots[lookupKey] else { return nil }
            s.clock += 1
            slot.recently = s.clock
            s.slots[lookupKey] = slot
            return slot.image
        }
    }

    /// The largest version lying at a prefix — for ``ImageLoader/saved(_:pixels:)``.
    func largest(withPrefix prefix: String) -> CGImage? {
        state.withLock { s in
            (s.byPrefix[Substring(prefix)] ?? []).compactMap { s.slots[$0]?.image }.max {
                $0.height < $1.height
            }
        }
    }

    public func create(_ image: CGImage, below lookupKey: String) {
        let cost = image.height * image.bytesPerRow
        state.withLock { s in
            if let previous = s.slots[lookupKey] { s.used -= previous.cost }
            s.clock += 1
            s.slots[lookupKey] = CachedImage(image: image, cost: cost, recently: s.clock)
            s.byPrefix[ImageStore.prefix(lookupKey), default: []].insert(lookupKey)
            s.used += cost
            ImageStore.cleanUp(&s, below: limit)
        }
    }

    /// On a memory warning: back to a quarter, not to zero — an empty store means every
    /// visible tile is fetched again, exactly when the system is short anyway.
    public func shrink(on fraction: Double = 0.25) {
        let ceiling = Int(Double(limit) * fraction)
        state.withLock { ImageStore.cleanUp(&$0, below: ceiling) }
    }

    public func clearOut() {
        state.withLock { $0 = Status() }
    }

    private static func cleanUp(_ s: inout Status, below ceiling: Int) {
        guard s.used > ceiling else { return }
        for lookupKey in s.slots.sorted(by: { $0.value.recently < $1.value.recently }).map(\.key) {
            guard s.used > ceiling else { return }
            s.remove(lookupKey)
        }
    }
}
