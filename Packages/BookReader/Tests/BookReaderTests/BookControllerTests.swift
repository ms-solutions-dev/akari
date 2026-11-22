import Foundation
import SourcesKit
import SourcesKitMocks
import Testing
import UIKit

@testable import BookReader

@Suite("Book controller")
@MainActor
struct BookControllerTests {

    private func file() throws -> URL {
        let target = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString).epub")
        try MockBook.epub(chapter: 3).write(to: target)
        return target
    }

    @Test("Readium opens the built EPUB: three entries, map, contents")
    func open() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = try await BookOpener.open(file)
        #expect(!opened.isPdf)
        #expect(opened.publication.readingOrder.count == 3)
        #expect(opened.spineCard?.spineStep == 6)
        #expect(opened.spineCard?.entries.count == 3)

        let style = ReadingStyle(persistence: UserDefaults(suiteName: "steuerung-test")!)
        let controller = BookController(
            book: ReaderBook(
                id: "p", name: "Die Probe", file: file,
                start: .position(cfi: "epubcfi(/6/4!/4/2[kap2]/6)", fraction: 0.4)),
            style: style)
        await controller.open(dark: false)
        #expect(controller.phase == .ready)
        #expect(controller.navigator != nil)
        #expect(controller.count > 3)
        #expect(controller.content.map(\.name) == ["Kapitel 1", "Kapitel 2", "Kapitel 3"])
        #expect(controller.page(from: controller.content[1]) != nil)
    }

    @Test("A file that does not exist is an error, not a crash")
    func missing() async {
        let controller = BookController(
            book: ReaderBook(id: "x", name: "Nichts", file: URL(fileURLWithPath: "/tmp/gibt-es-nicht.epub")),
            style: ReadingStyle(persistence: UserDefaults(suiteName: "steuerung-test")!))
        await controller.open(dark: false)
        guard case .failure = controller.phase else {
            Issue.record("expected: failure, was \(controller.phase)")
            return
        }
    }
}

@Suite("Book controller - in a window")
@MainActor
struct BookControllerWindowTests {

    /// The navigator only loads in a window; the reports arrive when the
    /// page is up. The whole chain is checked: start CFI -> jump -> paging ->
    /// CFI back, with spine entry and id assertion like foliate-js.
    @Test("Paging reports a CFI with chapter and paragraph")
    func cfiBack() async throws {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "fenster-\(UUID().uuidString).epub")
        try MockBook.epub(chapter: 3).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        final class Collector: @unchecked Sendable {
            var states: [ReadingState.Position] = []
        }
        let collector = Collector()
        let controller = BookController(
            book: ReaderBook(
                id: "p", name: "Die Probe", file: file,
                start: .position(cfi: "epubcfi(/6/4!/4/2[kap2]/12[k2a5])", fraction: 0.4),
                report: { spot, _ in collector.states.append(spot) }),
            style: ReadingStyle(persistence: UserDefaults(suiteName: "steuerung-fenster")!))
        // Without a UIApplication no page-turn animation finishes in the test process.
        controller.style.animation = false
        await controller.open(dark: false)
        let navigator = try #require(controller.navigator)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigator
        window.makeKeyAndVisible()
        for _ in 0..<60 where controller.page == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(controller.page > 0)
        #expect(controller.chapter == "Kapitel 2")
        controller.proceed()
        for _ in 0..<60 where collector.states.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let last = try #require(collector.states.last)
        guard case .position(let cfi, let fraction) = last else {
            Issue.record("no CFI: \(last)")
            return
        }
        #expect(cfi.hasPrefix("epubcfi(/6/4!/4/2[kap2]/"))
        #expect(cfi.contains("[k2a"))
        #expect(fraction > 0.3 && fraction < 0.8)
        window.isHidden = true
    }
}
