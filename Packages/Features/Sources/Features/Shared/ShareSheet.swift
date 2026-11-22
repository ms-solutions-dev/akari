import Bedrock
import DesignSystem
import Device
import Library
import NetworkLocation
import OfflineStore
import SourcesKit
import SwiftUI

/// "Share" in the context menu: fetches the whole file (from the offline store if it is
/// there, otherwise into the cache), gives it the title's name and hands it to the system:
/// AirDrop, Files, Mail. Audiobooks have no single file and no entry.
struct ShareSheet: View {

    let title: Title

    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock
    @Environment(NetworkWatch.self) private var network
    @Environment(\.imageTransport) private var transport
    @Environment(\.dismiss) private var close
    @State private var running = false
    @State private var fraction = 0.0
    @State private var bytes: Int64 = 0
    @State private var file: ShareFile?
    @State private var raw: URL?
    /// The language key of the error; never a Swift description on screen.
    @State private var failure: String?

    var body: some View {
        Sheet(title: Text(app: "share.title")) {
            VStack(spacing: 16) {
                Cover(title, width: 120)
                Text(verbatim: Display(title, inBookSeries: false).name)
                    .font(Typography.title(.title3))
                    .multilineTextAlignment(.center)
                // What it costs before it starts: "Manga · 143 MB".
                Text(verbatim: detail)
                    .font(.footnote)
                    .foregroundStyle(ColorTheme.muted.color)
                if let failure {
                    Text(verbatim: Phrase.from("share.error") + " · " + Phrase.from(failure))
                        .font(.footnote)
                        .foregroundStyle(ColorTheme.muted.color)
                        .multilineTextAlignment(.center)
                } else if let raw {
                    // Two ways: the package that only Akari opens, with cover, series and
                    // blurb, or the bare file for everyone else.
                    VStack(spacing: 10) {
                        Button {
                            Task { await show(package: true, raw) }
                        } label: {
                            Text(app: "share.package").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.primary)
                        Text(app: "share.package.hint")
                            .font(.caption)
                            .foregroundStyle(ColorTheme.muted.color)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await show(package: false, raw) }
                        } label: {
                            Text(app: "share.file").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                    .padding(.top, 8)
                } else if running {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                    Text(verbatim: bytes > 0 ? Formats.bytes(bytes) : Phrase.from("share.fetches"))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(ColorTheme.muted.color)
                } else {
                    // Only the tap fetches; through the tunnel one volume takes an hour.
                    if !network.route.largeAmountsAcceptable, network.reported, title.kind == .manga {
                        Text(app: "keep.onTheGo")
                            .font(.caption)
                            .foregroundStyle(ColorTheme.muted.color)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        running = true
                        Task { await fetch() }
                    } label: {
                        Text(app: "share.send").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    .padding(.top, 8)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $file, onDismiss: { close() }) { file in
            ActivitySheet(address: file.address)
                .presentationDetents([.medium, .large])
        }
    }

    /// "Book · 1.2 MB", "Manga · 143 MB"; without a size only the kind.
    private var detail: String {
        let kind = Phrase.from(title.kind.lookupKey)
        guard let size = title.size, size > 0 else { return kind }
        return Phrase.from("share.size", kind, Formats.bytes(size))
    }

    private func fetch() async {
        guard let source = inventory.source(title.identifier.source) else {
            failure = "error.access"
            return
        }
        do {
            let raw: URL
            // Kept books are one file in the offline store; manga are pages there and
            // come as CBZ from the server.
            if title.kind == .book, let present = stock.files(title.identifier)?.first {
                raw = present
            } else {
                guard let address = source.file(title) else {
                    failure = "share.noFile"
                    return
                }
                raw = try await TempFile.fetch(
                    address, size: title.size, rangeCapable: true, headerLines: source.headerLines(),
                    transport: transport(title.identifier.source.provider)
                ) { b, a in
                    Task { @MainActor in
                        bytes = b
                        fraction = a
                    }
                }
            }
            self.raw = raw
        } catch {
            Diagnostics.network.error("Sharing failed: \(String(describing: error), privacy: .public)")
            failure = (error as? SourceError)?.messageKey ?? "error.unreachable"
        }
    }

    /// The package or the file with a readable name, then the system share sheet.
    private func show(package: Bool, _ raw: URL) async {
        do {
            let name = Display(title, inBookSeries: false).name
            if package {
                var cover: Data?
                if let address = title.cover,
                    let image = await ImageLoader.shared.image(
                        address, headerLines: inventory.headerLines(title.identifier.source), pixels: 800,
                        transport: transport(title.identifier.source.provider))
                {
                    cover = FileMetadata.jpeg(image)
                }
                let data = try DeviceSource.package(title, file: raw, cover: cover)
                file = ShareFile(
                    address: try ShareSheet.named(
                        data, name: name, fileExtension: "akari", series: title.series?.name))
            } else {
                file = ShareFile(
                    address: try ShareSheet.named(
                        raw, name: name, kind: title.kind, series: title.series?.name))
            }
        } catch {
            Diagnostics.network.error("Sharing failed: \(String(describing: error), privacy: .public)")
            failure = "error.unreadable"
        }
    }

    /// A copy with a readable name and the right extension in the temp folder: the cache
    /// is named `<sha>` without extension, and that is how it would otherwise arrive via
    /// AirDrop. The start of the file determines the extension (ZIP -> epub/cbz, %PDF -> pdf).
    nonisolated static func named(_ raw: URL, name: String, kind: Kind, series: String?) throws -> URL {
        let target = try targetPath(
            name: name, fileExtension: ShareSheet.fileExtension(raw, kind: kind), series: series)
        try FileManager.default.copyItem(at: raw, to: target)
        return target
    }

    /// The same for built data (the package).
    nonisolated static func named(
        _ data: Data, name: String, fileExtension: String, series: String?
    ) throws -> URL {
        let target = try targetPath(name: name, fileExtension: fileExtension, series: series)
        try data.write(to: target)
        return target
    }

    /// "Blawosfil Saga - Volume 1.cbz", but "Sherlock Holmes, Part 1-5.epub" instead of "Sherlock Holmes - Sherlock Holmes,
    /// Part 1-5.epub": the series comes first only if the name does not already mention it.
    nonisolated static func targetPath(name: String, fileExtension: String, series: String?) throws -> URL {
        let bookSeries = series.flatMap { name.localizedCaseInsensitiveContains($0) ? nil : $0 }
        let full = [bookSeries, name].compactMap { $0 }.joined(separator: " – ")
        let safe = full.map { "/:\\".contains($0) ? "-" : $0 }.reduce("") { $0 + String($1) }
        let target = FileManager.default.temporaryDirectory
            .appending(path: "teilen", directoryHint: .isDirectory)
            .appending(path: safe + "." + fileExtension)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        return target
    }

    nonisolated static func fileExtension(_ file: URL, kind: Kind) -> String {
        if !file.pathExtension.isEmpty { return file.pathExtension }
        guard let handle = try? FileHandle(forReadingFrom: file),
            let header = try? handle.read(upToCount: 4)
        else { return kind == .manga ? "cbz" : "epub" }
        try? handle.close()
        if header.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if header.starts(with: [0x50, 0x4B]) { return kind == .manga ? "cbz" : "epub" }
        return kind == .manga ? "cbz" : "epub"
    }
}

struct ShareFile: Identifiable {
    let address: URL
    var id: String { address.path }
}

#if canImport(UIKit)
    import UIKit

    /// The system share sheet with a file.
    struct ActivitySheet: UIViewControllerRepresentable {
        let address: URL

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: [address], applicationActivities: nil)
        }

        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }
#else
    struct ActivitySheet: View {
        let address: URL
        var body: some View {
            ShareLink(item: address) { Text(app: "share.title") }
                .padding(32)
        }
    }
#endif
