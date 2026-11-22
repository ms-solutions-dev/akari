import Bedrock
import Foundation
import SourcesKit

/// The "On this device" source: a folder under "Documents", one subfolder per
/// title — `inhalt.<extension>`, `metadaten.json`, `cover.<extension>`, `stand.json` and, for
/// manga, the unpacked pages under `seiten/`. No network, no account: whatever is
/// here, someone brought in (AirDrop, Files, mail) or shared as a package from a
/// server's shelf.
///
/// The comic reader reads pages via addresses, the book reader the file — both
/// are `file://` addresses here, and ``FileTransport`` answers them like a server.
public final class DeviceSource: Source, @unchecked Sendable {

    public static let server = "geraet"
    public static let identifier = SourceID(provider: .device, server: DeviceSource.server)

    public let folder: URL
    public var identifier: SourceID { DeviceSource.identifier }
    public let capabilities: Capabilities = [.seriesList]

    /// The app's folder under "Documents" — visible in the Files app so that one
    /// sees what the app keeps on the device.
    public static var documents: URL {
        let base =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Auf diesem Gerät", directoryHint: .isDirectory)
    }

    public init(folder: URL = DeviceSource.documents) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - Source

    public func verify() async throws {}

    public func library() async throws -> LibraryExtract {
        let entries = all()
        let title = entries.map(\.title)
        var states: [TitleID: ReadingState] = [:]
        for e in entries { if let s = e.state { states[e.title.identifier] = s } }
        // Series from the metadata — one series per name, with the cover of the first volume.
        var seriesList: [Series] = []
        let clusters = Dictionary(grouping: entries.filter { $0.metadata.bookSeries != nil }) {
            $0.metadata.bookSeries!.name
        }
        for (name, volumes) in clusters.sorted(by: { $0.key < $1.key }) {
            let first = volumes.sorted {
                ($0.metadata.bookSeries?.volume ?? 0) < ($1.metadata.bookSeries?.volume ?? 0)
            }[
                0]
            seriesList.append(
                Series(
                    identifier: DeviceSource.seriesIdentifier(name), kind: first.title.kind, name: name,
                    authors: first.title.authors, cover: first.title.cover, volumeCount: volumes.count,
                    language: first.title.language))
        }
        return LibraryExtract(
            source: identifier, seriesList: seriesList, title: title, readingStates: states, state: Date())
    }

    public func title(_ identifier: TitleID) async throws -> Title {
        guard let e = entry(identifier.id) else { throw SourceError.notFound(identifier) }
        return e.title
    }

    public func content(_ title: Title) -> ContentSource {
        let folder = folder(title.identifier.id)
        guard let e = entry(title.identifier.id) else {
            return .file(folder.appending(path: "inhalt.epub"), size: nil, rangeCapable: false)
        }
        let file = folder.appending(path: e.metadata.file)
        if e.metadata.kind == .manga {
            let pages = DeviceSource.pages(in: folder)
            // Reader and store count 1-based (page 1 = cover) like Komga. A plain
            // `pages[i]` here once dropped the cover and returned the last page twice.
            return .pageStream(count: pages.count) { page in
                pages.indices.contains(page - 1) ? pages[page - 1] : pages.last ?? file
            }
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return .file(file, size: size, rangeCapable: false)
    }

    /// For passing on: the file itself. The package with metadata is built by ``package(_:file:cover:)``.
    public func file(_ title: Title) -> URL? {
        guard let e = entry(title.identifier.id) else { return nil }
        return folder(title.identifier.id).appending(path: e.metadata.file)
    }

    public func headerLines() -> [String: String] { [:] }

    public func progress(_ identifier: TitleID) async throws -> ReadingState? {
        state(identifier.id)
    }

    public func write(_ state: ReadingState, for identifier: TitleID) async throws {
        let data = try PackageMetadata.encoder.encode(state)
        try data.write(to: folder(identifier.id).appending(path: "stand.json"), options: .atomic)
    }

    public func forget(progressFor identifier: TitleID) async throws {
        try? FileManager.default.removeItem(at: folder(identifier.id).appending(path: "stand.json"))
    }

    public func savedList() async throws -> Set<TitleID> {
        throw SourceError.notPossible(identifier, "The device has no saved list")
    }

    public func save(_ identifier: TitleID, saved: Bool) async throws {
        throw SourceError.notPossible(self.identifier, "The device has no saved list")
    }

    public func collections() async throws -> [TitleCollection] {
        throw SourceError.notPossible(identifier, "The device has no collections")
    }

    public func create(
        collection name: String, collectionKind: TitleCollection.CollectionKind
    ) async throws -> TitleCollection {
        throw SourceError.notPossible(identifier, "The device has no collections")
    }

    public func arrange(_ target: SaveTarget, in collection: CollectionID, into: Bool) async throws {
        throw SourceError.notPossible(identifier, "The device has no collections")
    }

    // MARK: - Importing

    public enum Failure: Error, Equatable {
        case unknownExtension(String)
        case packageWithoutMetadata
        case packageWithoutFile(String)
    }

    /// Takes in a file — EPUB, PDF, CBZ or an `.akari` package — and
    /// returns the identifier of the new title. The file is copied, the original
    /// stays where it was (the shell deletes the inbox itself).
    @discardableResult
    public func importFile(_ url: URL) throws -> TitleID {
        guard let kind = FileKind(url) else { throw Failure.unknownExtension(url.pathExtension) }
        let id = UUID().uuidString.lowercased()
        let target = folder(id)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            if kind == .akari {
                try unpackPackage(url, to: target)
            } else {
                let name = url.deletingPathExtension().lastPathComponent
                let finding = FileMetadata.extract(url, kind: kind, name: name)
                var meta = finding.metadata
                meta.file = "inhalt." + kind.rawValue
                try FileManager.default.copyItem(at: url, to: target.appending(path: meta.file))
                if let cover = finding.cover {
                    meta.cover = "cover." + finding.coverExtension
                    try cover.write(to: target.appending(path: meta.cover!))
                }
                try meta.json().write(to: target.appending(path: "metadaten.json"))
            }
            if let meta = metadata(id), meta.kind == .manga {
                try unpackPages(target.appending(path: meta.file), to: target.appending(path: "seiten"))
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return TitleID(source: identifier, id: id)
    }

    private func unpackPackage(_ url: URL, to target: URL) throws {
        let zip = try Zip(url: url)
        guard let json = try? zip.content("metadaten.json") else { throw Failure.packageWithoutMetadata }
        var meta = try PackageMetadata.from(json)
        guard let content = try? zip.content(meta.file) else { throw Failure.packageWithoutFile(meta.file) }
        let fileExtension = (meta.file as NSString).pathExtension.lowercased()
        meta.file =
            "inhalt." + (fileExtension.isEmpty ? (meta.kind == .manga ? "cbz" : "epub") : fileExtension)
        try content.write(to: target.appending(path: meta.file))
        if let cover = meta.cover, let image = try? zip.content(cover) {
            let coverExtension = (cover as NSString).pathExtension.lowercased()
            meta.cover = "cover." + (coverExtension.isEmpty ? "jpg" : coverExtension)
            try image.write(to: target.appending(path: meta.cover!))
        } else {
            meta.cover = nil
        }
        try meta.json().write(to: target.appending(path: "metadaten.json"))
    }

    /// The pages of a CBZ as files — the comic reader reads addresses, not an archive.
    private func unpackPages(_ cbz: URL, to target: URL) throws {
        let zip = try Zip(url: cbz)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (i, e) in FileMetadata.pages(zip).enumerated() {
            let fileExtension = (e.name as NSString).pathExtension.lowercased()
            try zip.content(e).write(to: target.appending(path: String(format: "%05d.", i) + fileExtension))
        }
    }

    /// Deletes a title including file and state from the device.
    public func erase(_ identifier: TitleID) throws {
        try FileManager.default.removeItem(at: folder(identifier.id))
    }

    // MARK: - Building a package

    /// An `.akari` package from a file and what the library knows about the title —
    /// for "share as Akari package". The cover is included if there is one.
    public static func package(_ title: Title, file: URL, cover: Data?) throws -> Data {
        let fileExtension =
            file.pathExtension.isEmpty ? (title.kind == .manga ? "cbz" : "epub") : file.pathExtension
        let name = "inhalt." + fileExtension
        let meta = PackageMetadata(title, file: name, cover: cover == nil ? nil : "cover.jpg")
        var entries: [(name: String, data: Data)] = [
            ("metadaten.json", try meta.json()),
            (name, try Data(contentsOf: file)),
        ]
        if let cover { entries.append(("cover.jpg", cover)) }
        return Zip.archive(entries)
    }

    // MARK: - Folder

    struct Item {
        let id: String
        let metadata: PackageMetadata
        let title: Title
        let state: ReadingState?
    }

    func folder(_ id: String) -> URL { folder.appending(path: id, directoryHint: .isDirectory) }

    func metadata(_ id: String) -> PackageMetadata? {
        guard let data = try? Data(contentsOf: folder(id).appending(path: "metadaten.json")) else {
            return nil
        }
        return try? PackageMetadata.from(data)
    }

    func state(_ id: String) -> ReadingState? {
        guard let data = try? Data(contentsOf: folder(id).appending(path: "stand.json")) else { return nil }
        return try? PackageMetadata.decoder.decode(ReadingState.self, from: data)
    }

    func entry(_ id: String) -> Item? {
        guard let meta = metadata(id) else { return nil }
        let folder = folder(id)
        let file = folder.appending(path: meta.file)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let added = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate
        let scope: Scope = meta.pages.map { .pages($0) } ?? .unknown
        let title = Title(
            identifier: TitleID(source: identifier, id: id), kind: meta.kind, name: meta.name,
            subtitle: meta.subtitle, authors: meta.authors,
            series: meta.bookSeries.map {
                SeriesReference(
                    identifier: DeviceSource.seriesIdentifier($0.name), name: $0.name, volume: $0.volume)
            },
            cover: meta.cover.map { folder.appending(path: $0) }, genres: meta.genres,
            summary: meta.summary, scope: scope, language: meta.language, publisher: meta.publisher,
            added: added ?? meta.createdAt, size: size,
            format: Title.format(file.pathExtension))
        return Item(id: id, metadata: meta, title: title, state: state(id))
    }

    func all() -> [Item] {
        guard
            let names = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }
        return names.compactMap { entry($0.lastPathComponent) }
            .sorted { $0.title.name.localizedStandardCompare($1.title.name) == .orderedAscending }
    }

    static func pages(in folder: URL) -> [URL] {
        let pages = folder.appending(path: "seiten", directoryHint: .isDirectory)
        guard
            let names = try? FileManager.default.contentsOfDirectory(
                at: pages, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }
        return names.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func seriesIdentifier(_ name: String) -> SeriesID {
        SeriesID(
            source: identifier, id: "reihe-" + name.lowercased().replacingOccurrences(of: " ", with: "-"))
    }
}

/// Answers `file://` requests like a server: the file's data, status 200 — or
/// 404. Covers, pages and the book reader would otherwise go through `URLSession`, which
/// gives no `HTTPURLResponse` for files.
public struct FileTransport: Transport {

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.isFileURL else { throw URLError(.unsupportedURL) }
        guard let data = try? Data(contentsOf: url) else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        return (
            data,
            HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": String(data.count)])!
        )
    }
}
