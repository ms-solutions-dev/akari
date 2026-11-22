import AccountsKit
import AudioPlayer
import Bedrock
import Foundation
import Library
import NetworkLocation
import OfflineStore
import SourcesKit
import SourcesKitMocks

/// The app in the bad case: `AKARI_PROBE=stoerung:<case>` with `-attrappen`.
///
/// Every checklist used to test only the good case. This probe makes the mocks fail
/// artificially, the way servers do: a container down (``komgaOff``), a key revoked
/// (``expired``), a reverse proxy without backend (``serverDisruption``), a new
/// certificate (``certificate``), the network dropping mid-volume (``pages``), reading
/// offline and syncing afterwards (``queue``), two devices (``conflict``), the audio
/// (``audiobook``), the tunnel (``slow``), an interrupted download (``download``).
/// ``configure(_:)`` sets up the mocks before the shell is up; ``play(_:)`` is the
/// schedule afterwards (network off, network back) so that a screenshot shows without
/// any touch what the app makes of it.
enum DisruptionProbe: String, CaseIterable, Sendable {
    case komgaOff = "komga-aus"
    case grimmoryOff = "grimmory-aus"
    case absOff = "abs-aus"
    case allOff = "alle-aus"
    case expired = "401"
    case serverDisruption = "502"
    case certificate = "zertifikat"
    case pages = "seiten"
    case queue = "warteschlange"
    case conflict = "konflikt"
    case audiobook = "hoerbuch"
    case slow = "langsam"
    case slowStart = "langsam-start"
    case download

    /// The probe from the environment, or `nil` if no disruption is requested.
    static var present: DisruptionProbe? {
        from(ProcessInfo.processInfo.environment["AKARI_PROBE"])
    }

    /// Reads `stoerung:<case>`; the one place that knows the spelling.
    static func from(_ value: String?) -> DisruptionProbe? {
        guard let value, value.hasPrefix("stoerung:") else { return nil }
        return DisruptionProbe(rawValue: String(value.dropFirst("stoerung:".count)))
    }

    /// Which ordinary probe the start page should run for it: the series detail for the
    /// download; the schedule opens the readers itself.
    var opens: String? {
        switch self {
        case .download: "serie"
        default: nil
        }
    }

    /// Which sources are "off".
    private var from: Set<Provider> {
        switch self {
        case .komgaOff, .certificate: [.komga]
        case .grimmoryOff: [.grimmory]
        case .absOff: [.audiobookshelf]
        case .allOff: [.komga, .grimmory, .audiobookshelf]
        default: []
        }
    }

    /// Sets up the mocks before the shell asks for the first time: the extracts into
    /// persistence (the start should come from the cache, which is exactly what the probe
    /// checks), then the disruption.
    func configure(
        sources: [MockSource], transport: MockTransport, questions: CertificateQuestion,
        persistence: LibraryStore
    ) {
        for source in sources { _ = try? persistence.write(source.extract) }
        for source in sources where from.contains(source.identifier.provider) {
            source.set(network: .unreachable)
        }
        let komga = sources.first { $0.identifier.provider == .komga }
        switch self {
        case .expired:
            komga.map { $0.set(disruption: .signedOut($0.identifier)) }
        case .serverDisruption:
            komga.map { $0.set(disruption: .serverDisruption($0.identifier, status: 502)) }
        case .certificate:
            questions.spot(
                CertificateQuestion.Unresolved(
                    host: komga?.identifier.server ?? "comics.example",
                    fingerprint: CertificateFingerprint(certificateData: Data("neu-2026-09-19".utf8)),
                    known: CertificateFingerprint(certificateData: Data("alt-2026-09-12".utf8))))
        case .grimmoryOff:
            // The "server" is off, for the file too: the transport fails, and the book
            // from an earlier run is no longer in the cache.
            transport.set(outage: .cannotConnectToHost)
            for book in sources.flatMap(\.extract.title) where book.kind == .book {
                if case .file(let address, _, _) = sources[1].content(book) {
                    try? FileManager.default.removeItem(at: TempFile.path(for: address))
                }
            }
        case .pages, .slow, .download:
            // What an earlier run put on disk would otherwise come from there, and the
            // disruption would hit nothing.
            try? FileManager.default.removeItem(at: Cache.folder.appending(path: "seiten"))
            if self == .slow { transport.set(delay: .seconds(5)) }
        default:
            break
        }
    }

    /// Everything the schedule may touch.
    @MainActor
    struct Stage {
        let sources: [MockSource]
        let transport: MockTransport
        let network: NetworkWatch
        let inventory: LibraryService
        let reader: ReadCall
        let stock: StockService
        let player: Player
        let metering: NetworkMeter
        let imageTransport: @Sendable (Provider) -> any Transport

        fileprivate func source(_ provider: Provider) -> MockSource? {
            sources.first { $0.identifier.provider == provider }
        }

        fileprivate func title(_ kind: Kind, number: Int = 0) -> Title? {
            let all = inventory.shelf.allTitles.filter { $0.kind == kind }
            return all.indices.contains(number) ? all[number] : nil
        }

        /// Network off: the watcher reports no path, the transport fails, and so do the
        /// sources, all three, as in airplane mode.
        fileprivate func networkOff() {
            transport.set(outage: .networkConnectionLost)
            for q in sources { q.set(network: .unreachable) }
            network.adopt(.none)
        }

        fileprivate func networkBack() {
            transport.set(outage: nil)
            for q in sources { q.set(network: .reachable) }
            network.adopt(NetworkPath(kind: .wifi))
        }
    }

    /// The schedule after the first frame. Seconds since launch are given in the comments
    /// so that the screenshots taken by the test script line up.
    @MainActor
    func play(_ b: Stage) async {
        // A cancelled schedule (the shell rebuilds the context) stops instead of catching
        // up on its steps instantly; `Task.sleep` throws immediately on cancellation.
        func wait(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
        Diagnostics.step("Disruption probe \(rawValue) running", since: nil, area: "Probe")
        do { try await schedule(b, wait: wait) } catch { return }
    }

    @MainActor
    private func schedule(_ b: Stage, wait: (Double) async throws -> Void) async throws {
        switch self {
        case .komgaOff, .absOff, .allOff, .expired, .serverDisruption, .certificate:
            break
        case .grimmoryOff:
            // 3 s: open a book that was not downloaded, showing the fetch-failure sheet
            // with a sentence and "Try again", not the description of a URLError.
            try await wait(3)
            b.title(.book, number: 2).map { b.reader.open($0) }
        case .pages:
            // 2 s: the started volume opens (with `AKARI_BLAETTERPROBE=6` it turns a page
            // every 6 s). 8 s: network off, the shown page stays, the fourth after it
            // is missing. 40 s: network back, the reader fetches it by itself.
            try await wait(2)
            b.title(.manga, number: 1).map { b.reader.open($0) }
            try await wait(6)
            b.networkOff()
            try await wait(32)
            b.networkBack()
        case .queue:
            // 2 s: network off. 4 s: two states written, as readers do; they stay on the
            // shelf and wait. 20 s: network back, delivered later, with a message.
            try await wait(2)
            b.networkOff()
            try await wait(2)
            if let volume = b.title(.manga, number: 1) {
                try? await b.inventory.write(
                    ReadingState(
                        position: .page(90, from: 205), timestamp: Date(), device: DeviceName.thisDevice),
                    for: volume.identifier)
            }
            if let book = b.title(.book, number: 1) {
                try? await b.inventory.write(
                    ReadingState(
                        position: .position(cfi: "epubcfi(/6/6!/4/2[kap3]/2)", fraction: 0.62),
                        timestamp: Date(),
                        device: DeviceName.thisDevice),
                    for: book.identifier)
            }
            try await wait(16)
            b.networkBack()
        case .conflict:
            // 1.5 s: the iPad kept reading on the "server", further than here, and newer.
            // 3 s: the book opens and the conflict sheet asks.
            try await wait(1.5)
            if let book = b.title(.book, number: 1), let grimmory = b.source(.grimmory) {
                try? await grimmory.write(
                    ReadingState(
                        position: .position(cfi: "epubcfi(/6/6!/4/2[kap3]/6[k3a2])", fraction: 0.71),
                        timestamp: Date(), device: "Alex's iPad"),
                    for: book.identifier)
                try await wait(1.5)
                b.reader.open(book)
            }
        case .audiobook:
            // 1 s: the started audiobook plays. 4 s: network off, the preloaded track
            // keeps playing from the buffer, the next one fails; at the end of the track
            // the player stops cleanly and says so. 75 s: network back. 80 s: play, continue.
            try await wait(1)
            b.title(.audiobook, number: 0).map { b.reader.open($0) }
            try await wait(3)
            b.networkOff()
            try await wait(71)
            b.networkBack()
            try await wait(5)
            b.player.play()
        case .slow:
            // The transport takes 5 s per response (``configure(_:)``). 2 s: the volume
            // opens, every page takes a while, the "On the go" toast appears, the speed
            // is measured.
            try await wait(2)
            b.title(.manga, number: 1).map { b.reader.open($0) }
        case .slowStart:
            // Two measurements, as two manga pages through the tunnel would deliver:
            // 700 kB in 18 s, the banner on Start.
            try await wait(1)
            b.metering.save(bytes: 700_000, startTime: 0, end: 18)
            b.metering.save(bytes: 690_000, startTime: 18, end: 37)
        case .download:
            // 2 s: download volume 48, one page per second. 8 s: network off, the
            // download breaks off, what is there stays. 14 s: network back, the shell
            // resumes, the first pages come from disk.
            b.transport.set(delay: .seconds(1))
            try await wait(2)
            if let volume = b.title(.manga, number: 2), let source = b.source(.komga) {
                b.stock.requestKeep(volume, source: source, transport: b.imageTransport(.komga))
            }
            try await wait(6)
            b.networkOff()
            try await wait(6)
            b.transport.set(delay: .seconds(0.3))
            b.networkBack()
        }
    }
}
