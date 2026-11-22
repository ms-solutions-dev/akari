import Foundation
import Library
import SourcesKit
import SourcesKitMocks
import SwiftUI
import Testing

@testable import Features

@Suite("Comic reader bridge")
@MainActor
struct ReaderTests {

    private func service() -> (LibraryService, [MockSource]) {
        let persistence = LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "leser-\(UUID().uuidString)"))
        let sources = MockShelf.base()
        return (LibraryService(persistence: persistence) { sources }, sources)
    }

    @Test(
        "The position reporter coalesces: first page immediately, then at the earliest after two seconds, the rest on close"
    )
    func coalesce() async throws {
        let (inventory, sources) = service()
        await inventory.refresh()
        let volume = try #require(inventory.shelf.allTitles.first { $0.kind == .manga })
        let reporter = PositionReporter()
        reporter.inventory = inventory
        reporter.report(3, from: 200, for: volume.identifier, completed: false)
        reporter.report(4, from: 200, for: volume.identifier, completed: false)
        reporter.report(5, from: 200, for: volume.identifier, completed: false)
        try await Task.sleep(for: .milliseconds(100))
        // One write: page 3. Pages 4 and 5 wait.
        #expect(sources[0].written.count == 1)
        #expect(sources[0].written.first?.1.position == .page(3, from: 200))
        reporter.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sources[0].written.count == 2)
        #expect(sources[0].written.last?.1.position == .page(5, from: 200))
        #expect(sources[0].written.last?.1.device != nil)
        #expect(inventory.shelf.readingState(volume.identifier)?.position == .page(5, from: 200))
    }

    @Test("The last page writes \"done\"")
    func done() async throws {
        let (inventory, sources) = service()
        await inventory.refresh()
        let volume = try #require(inventory.shelf.allTitles.first { $0.kind == .manga })
        let reporter = PositionReporter()
        reporter.inventory = inventory
        reporter.report(200, from: 200, for: volume.identifier, completed: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sources[0].written.last?.1.completed == true)
    }

    @Test("Without a library the reporter reports into the void, without crashing")
    func withoutLibrary() {
        let reporter = PositionReporter()
        reporter.report(
            1, from: 10, for: TitleID(source: SourceID(provider: .komga, server: "x"), id: "y"),
            completed: false)
        reporter.finish()
    }
}

@Suite("Book reader bridge")
@MainActor
struct BookReaderBridgeTests {

    @Test("A CFI from the book reader goes to the source as a position; Grimmory writes it that way")
    func cfi() async throws {
        let persistence = LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "buch-\(UUID().uuidString)"))
        let sources = MockShelf.base()
        let inventory = LibraryService(persistence: persistence) { sources }
        await inventory.refresh()
        let book = try #require(inventory.shelf.allTitles.first { $0.kind == .book })
        let source = try #require(sources.first { $0.identifier == book.identifier.source })
        let reporter = PositionReporter()
        reporter.inventory = inventory
        reporter.report(
            .position(cfi: "epubcfi(/6/4!/4/2[kap2]/6)", fraction: 0.42), for: book.identifier,
            completed: false)
        try await Task.sleep(for: .milliseconds(100))
        let state = try #require(source.written.last?.1)
        #expect(state.position == .position(cfi: "epubcfi(/6/4!/4/2[kap2]/6)", fraction: 0.42))
        #expect(state.fraction == 0.42)
        #expect(PositionReporter.short(state.position) == "epubcfi(/6/4!/4/2[kap2]/6) (42 %)")
    }

    @Test("Without a plugged-in reader there is no factory; the environment is empty")
    func slot() {
        let environment = EnvironmentValues()
        #expect(environment.bookReader == nil)
    }
}

@Suite("Reading-time measuring points")
struct ReadingTimeTests {
    @Test("The span of a session: pages, seconds, otherwise percent")
    func span() {
        #expect(
            PositionReporter.span(from: .page(3, from: 200), until: .page(31, from: 200))
                == "Page 3 → 31 of 200"
        )
        #expect(
            PositionReporter.span(from: .second(120, from: 900), until: .second(900, from: 900))
                == "120 s → 900 s"
        )
        #expect(
            PositionReporter.span(
                from: .position(cfi: "a", fraction: 0.4), until: .position(cfi: "b", fraction: 0.52))
                == "40 % → 52 %")
        #expect(PositionReporter.span(from: .page(1, from: 10), until: .fraction(0.5)) == "10 % → 50 %")
    }
}

@Suite("Sharing")
struct ShareTests {
    @Test("The extension comes from the file start: %PDF, PK as EPUB or CBZ, otherwise the address's")
    func fileExtension() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "teilen-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appending(path: "a")
        try Data([0x25, 0x50, 0x44, 0x46, 0x2D]).write(to: pdf)
        let zip = folder.appending(path: "b")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zip)
        #expect(ShareSheet.fileExtension(pdf, kind: .book) == "pdf")
        #expect(ShareSheet.fileExtension(zip, kind: .book) == "epub")
        #expect(ShareSheet.fileExtension(zip, kind: .manga) == "cbz")
        #expect(ShareSheet.fileExtension(folder.appending(path: "c.epub"), kind: .book) == "epub")
        let copy = try ShareSheet.named(zip, name: "Band 1", kind: .manga, series: "Blawosfil Saga: Teil/1")
        #expect(copy.lastPathComponent == "Blawosfil Saga- Teil-1 – Band 1.cbz")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        try? FileManager.default.removeItem(at: folder)
    }
}
