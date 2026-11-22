import Bedrock
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PerformanceDiagnostics
import SourcesKit

/// A loaded page: the image at screen size and how long it took.
public struct PageImage: Sendable {
    public let image: CGImage
    /// Seconds from request to image - only measured when it came over the network;
    /// from memory or disk it is `nil`. The "On the way
    /// ~19 s per page" toast depends on it.
    public let duration: TimeInterval?

    public var width: Int { image.width }
    public var height: Int { image.height }
}

/// Fetches the pages of a volume and keeps them ready - from the device, from disk
/// or from the server, in that order.
///
/// **Three sources, one call:** a kept volume exists as files
/// (`files`), everything else comes via the source's address and lands in the
/// cache (`folder`), so paging back is not a second trip through
/// the tunnel. The loader knows no servers - it is given addresses, header lines and transport,
/// like the `ImageLoader`.
///
/// **Downscaled while decoding:** pages up to 2,707 px wide are 42 MB each
/// unpacked; brought to the longer screen edge (2,622 px
/// on iPhone 17 Pro) about 18 MB remain, and memory holds only as many of them
/// as `limit` allows. Bytes on disk cost nothing - the
/// preload window fetches bytes, not images.
///
/// **Decoding happens beside the loader, not on it**: `downscaled` ran
/// in ``create``, i.e. on the actor - one decode after the other, and every call of
/// ``image(_:)`` waited until the queue was through. In the webtoon twenty
/// pages appear at once while scrolling; twenty times ten milliseconds in a row are a fifth
/// of a second until the last one stands. Now a task of its own decodes, the actor stays
/// free for memory hits and new downloads.
///
/// **And it measures itself** (diagnostics, only while recording): per page source, network,
/// disk and decode duration as measurement series, the queue as a level, and anything above
/// ``slowFrom`` as a note with all parts.
public actor PageLoader {

    /// From this many milliseconds on a page is listed individually in the diagnostics log.
    static let slowFrom = 300.0

    private let count: Int
    private let address: @Sendable (Int) -> URL
    private let files: [URL]?
    private let headerLines: [String: String]
    private let transport: any Transport
    private let folder: URL?
    private let pixels: Int
    private let byWidth: Bool
    private let limit: Int

    private struct Slot {
        let image: PageImage
        let cost: Int
        var recently: UInt64
    }
    private var slots: [Int: Slot] = [:]
    private var used = 0
    private var clock: UInt64 = 0
    /// A download and how many views are still waiting for it.
    private struct Job {
        let task: Task<PageImage?, Never>
        var waiting: Int
    }
    private var ongoing: [Int: Job] = [:]
    private var preloading: [Int: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - count: pages in the volume
    ///   - address: the address of a page (1-based)
    ///   - files: the pages on the device, index 0 = page 1 - a kept volume
    ///   - headerLines: what the source attaches to every request
    ///   - transport: the source's session
    ///   - folder: the cache for fetched pages; `nil` switches it off
    ///   - pixels: the longer screen edge in pixels - with `byWidth`
    ///     the screen width
    ///   - byWidth: downscaled to the width instead of the longer edge; for
    ///     webtoons whose strips can be much taller than wide and would otherwise shrink to
    ///     a fraction of the width
    ///   - limit: bytes of decoded pages in memory; 100 MB is five
    ///     iPhone pages - the shown one, two back, two ahead
    public init(
        count: Int, address: @escaping @Sendable (Int) -> URL, files: [URL]? = nil,
        headerLines: [String: String] = [:], transport: any Transport = URLSession.shared, folder: URL?,
        pixels: Int, byWidth: Bool = false, limit: Int = 100 * 1024 * 1024
    ) {
        self.count = count
        self.address = address
        self.files = files
        self.headerLines = headerLines
        self.transport = transport
        self.folder = folder
        self.pixels = max(pixels, 64)
        self.byWidth = byWidth
        self.limit = limit
    }

    /// The image of the page - or `nil` if it does not arrive. A second caller
    /// for the same page attaches to the first.
    ///
    /// **Cancels when nobody is waiting anymore**: the
    /// download used to keep running as its own `Task` even when the page was long off screen.
    /// Fast swiping through hundreds of pages in the webtoon put hundreds of downloads on
    /// the line, and the shown page arrived after 8-10 s instead of 0.3 s.
    ///
    /// **A hit from memory carries no duration**: the remembered
    /// ``PageImage`` kept the network duration of the first fetch, and every view that asked
    /// for the page again afterwards reported "Page loaded slowly: 8.2 s" - the same
    /// page three times in the device report, and the "On the way" toast appeared for a page that
    /// was long there.
    public func image(_ page: Int) async -> PageImage? {
        guard (1...max(count, 1)).contains(page) else { return nil }
        if var slot = slots[page] {
            clock += 1
            slot.recently = clock
            slots[page] = slot
            Performance.measure("Page from memory", 1)
            return PageImage(image: slot.image.image, duration: nil)
        }
        let startTime = ContinuousClock.now
        let task: Task<PageImage?, Never>
        if var job = ongoing[page] {
            job.waiting += 1
            ongoing[page] = job
            task = job.task
        } else {
            task = Task<PageImage?, Never> { await fetch(page) }
            ongoing[page] = Job(task: task, waiting: 1)
        }
        reportLevel()
        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(page, task) }
        }
        if ongoing[page]?.task == task { ongoing[page] = nil }
        reportLevel()
        Performance.measure("Page to image ms", (ContinuousClock.now - startTime).milliseconds)
        return image
    }

    /// The loader's queue for the time series: requested and preloaded pages.
    private func reportLevel() {
        guard Performance.records else { return }
        Performance.level("Loader queue", ongoing.count + preloading.count)
    }

    /// A waiter has cancelled; if it was the last, the download drops.
    private func leave(_ page: Int, _ task: Task<PageImage?, Never>) {
        guard var job = ongoing[page], job.task == task else { return }
        job.waiting -= 1
        if job.waiting > 0 {
            ongoing[page] = job
        } else {
            task.cancel()
            ongoing[page] = nil
        }
    }

    /// Fetches the bytes of the pages in the window onto disk - and drops what
    /// lies outside and is still in flight. Decoding only happens on display.
    ///
    /// `around`: the shown page - the next ones go onto the line first, not the
    /// topmost of the window (when scrolling up in the webtoon the needed page used to lie
    /// behind twenty others). What is just being fetched for display is not fetched a
    /// second time by preloading.
    public func preload(_ window: ClosedRange<Int>, around page: Int? = nil) {
        for (page, task) in preloading where !window.contains(page) {
            task.cancel()
            preloading[page] = nil
        }
        guard files == nil, folder != nil else { return }
        let bookSeries =
            page.map { center in window.sorted { abs($0 - center) < abs($1 - center) } } ?? Array(window)
        for page in bookSeries
        where preloading[page] == nil && ongoing[page] == nil && slots[page] == nil
            && !isOnDisk(page)
        {
            preloading[page] = Task { [weak self] in
                _ = try? await self?.fromNetwork(page)
                await self?.preloaded(page)
            }
        }
        reportLevel()
    }

    private func preloaded(_ page: Int) {
        preloading[page] = nil
        reportLevel()
    }

    /// Throws away the decoded images - on a memory warning; the bytes on
    /// disk stay, and the next page comes from there in milliseconds.
    public func emptyStore() {
        slots.removeAll()
        used = 0
    }

    // MARK: - Internals

    private func fetch(_ page: Int) async -> PageImage? {
        let startTime = ContinuousClock.now
        if let files {
            guard page - 1 < files.count, let data = try? Data(contentsOf: files[page - 1]) else {
                return nil
            }
            Performance.measure("Page from file ms", (ContinuousClock.now - startTime).milliseconds)
            return await create(page, data, duration: nil, source: "File", startTime: startTime)
        }
        if let path = path(page), let data = try? Data(contentsOf: path) {
            Performance.measure("Page from disk ms", (ContinuousClock.now - startTime).milliseconds)
            return await create(page, data, duration: nil, source: "Disk", startTime: startTime)
        }
        // If preloading is already loading the page, wait for it instead of fetching it a second time.
        if let upfront = preloading[page] {
            await upfront.value
            if let path = path(page), let data = try? Data(contentsOf: path) {
                Performance.measure(
                    "Page waited for preload ms", (ContinuousClock.now - startTime).milliseconds)
                return await create(
                    page, data, duration: (ContinuousClock.now - startTime).asSeconds, source: "Preload",
                    startTime: startTime)
            }
        }
        do {
            let data = try await fromNetwork(page)
            Performance.measure("Page from network ms", (ContinuousClock.now - startTime).milliseconds)
            return await create(
                page, data, duration: (ContinuousClock.now - startTime).asSeconds, source: "Network",
                startTime: startTime)
        } catch is CancellationError {
            Performance.measure("Page cancelled", 1)
            return nil
        } catch {
            Diagnostics.network.error(
                "Page \(page, privacy: .public) not fetched: \(String(describing: error), privacy: .public)"
            )
            Performance.remark("p. \(page) not fetched: \(NetworkErrorText.short(error))")
            return nil
        }
    }

    /// Bytes from the server, then onto disk. Whoever requests the page in parallel
    /// reads it from there.
    private func fromNetwork(_ page: Int) async throws -> Data {
        if let path = path(page), let data = try? Data(contentsOf: path) { return data }
        var request = URLRequest(url: address(page))
        for (name, value) in headerLines { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let folder, let path = path(page) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: path, options: .atomic)
        }
        return data
    }

    /// Decodes beside the actor and puts the image into memory. `source` and `start`
    /// are for diagnostics: where the bytes came from and how long everything took together.
    private func create(
        _ page: Int, _ data: Data, duration: TimeInterval?, source: String, startTime: ContinuousClock.Instant
    ) async -> PageImage? {
        let pixels = pixels
        let byWidth = byWidth
        let decodeStart = ContinuousClock.now
        let decoded = await Task.detached(priority: .userInitiated) {
            PageLoader.downscaled(data, on: pixels, byWidth: byWidth)
        }.value
        let decodeMs = (ContinuousClock.now - decodeStart).milliseconds
        Performance.measure("Page decode ms", decodeMs)
        guard let image = decoded else {
            Diagnostics.network.error(
                "Page \(page, privacy: .public) unreadable (\(data.count, privacy: .public) bytes)")
            return nil
        }
        let totalMs = (ContinuousClock.now - startTime).milliseconds
        if totalMs >= PageLoader.slowFrom {
            Performance.remark(
                String(
                    format: "p. %d from %@ after %.0f ms (decode %.0f ms, %d KB, %d running, %d preloading)",
                    page, source, totalMs, decodeMs, data.count / 1024, ongoing.count, preloading.count))
        }
        let pageImage = PageImage(image: image, duration: duration)
        let cost = image.height * image.bytesPerRow
        if let old = slots[page] { used -= old.cost }
        clock += 1
        slots[page] = Slot(image: pageImage, cost: cost, recently: clock)
        used += cost
        // Evict what has not been shown for longest - never the one just stored.
        while used > limit, slots.count > 1,
            let oldest = slots.filter({ $0.key != page }).min(by: { $0.value.recently < $1.value.recently }
            )
        {
            used -= oldest.value.cost
            slots[oldest.key] = nil
        }
        return pageImage
    }

    private func isOnDisk(_ page: Int) -> Bool {
        guard let path = path(page) else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// A hash of the address - the folder carries neither server name nor title.
    private func path(_ page: Int) -> URL? {
        guard let folder else { return nil }
        let digest = SHA256.hash(data: Data(address(page).absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: digest)
    }

    /// Builds the image directly at target size - never larger than the original.
    ///
    /// With `byWidth`, `pixels` is the target width: the limit for the longer
    /// edge grows with the aspect ratio, so a 720 x 15000 strip stays
    /// 720 wide instead of shrinking to 134.
    nonisolated static func downscaled(
        _ data: Data, on pixels: Int, byWidth: Bool = false
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var pixels = pixels
        if byWidth,
            let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = values[kCGImagePropertyPixelWidth] as? Int,
            let height = values[kCGImagePropertyPixelHeight] as? Int, width > 0
        {
            let longer = max(width, height)
            pixels =
                width <= pixels
                ? longer : Int((Double(longer) * Double(pixels) / Double(width)).rounded(.up))
        }
        let presets: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, presets as CFDictionary)
    }
}

extension Duration {
    var asSeconds: TimeInterval {
        let (s, attoseconds) = components
        return TimeInterval(s) + TimeInterval(attoseconds) / 1e18
    }

    var milliseconds: Double { asSeconds * 1000 }
}

/// An error in one word for the diagnostics log - without the address.
enum NetworkErrorText {
    static func short(_ failure: any Error) -> String {
        guard let u = failure as? URLError else { return String(describing: Swift.type(of: failure)) }
        switch u.code {
        case .timedOut: return "timed out"
        case .notConnectedToInternet: return "no network"
        case .networkConnectionLost: return "connection lost"
        case .cannotConnectToHost: return "server unreachable"
        case .badServerResponse: return "response not 2xx"
        default: return "URLError \(u.code.rawValue)"
        }
    }
}
