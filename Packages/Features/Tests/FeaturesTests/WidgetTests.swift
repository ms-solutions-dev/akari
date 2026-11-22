import Foundation
import Library
import OfflineStore
import SourcesKit
import SourcesKitMocks
import Testing
import WidgetBridge

@testable import Features

@Suite("Widget \"Continue reading\" and handoff")
@MainActor
struct WidgetTests {

    private func shelf() async -> Shelf {
        let persistence = LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "widget-\(UUID().uuidString)"))
        let sources = MockShelf.base()
        let inventory = LibraryService(persistence: persistence) { sources }
        await inventory.refresh()
        return inventory.shelf
    }

    private func reading(
        _ id: String, fraction: Double, before seconds: TimeInterval, cover: Bool = true
    )
        -> Shelf.Reading
    {
        let source = SourceID(provider: .grimmory, server: "buecher.example")
        let title = Title(
            identifier: TitleID(source: source, id: id), kind: .book, name: "Buch \(id)",
            authors: ["Jemand"],
            cover: cover ? URL(string: "https://buecher.example/cover/\(id)") : nil)
        return Shelf.Reading(
            title: title,
            state: ReadingState(
                position: .fraction(fraction), timestamp: Date().addingTimeInterval(-seconds)))
    }

    @Test("The snapshot follows the continue-reading row: order, cap of four, link into the reader")
    func fromStartRows() async throws {
        let shelf = await shelf()
        let readings = shelf.continueReading
        #expect(readings.count >= 4)
        let s = ContinueReadingSnapshot.from(readings, profile: "Alex", multipleProfiles: true)
        #expect(s.entries.count == ContinueReadingSnapshot.cap)
        #expect(s.entries.map(\.id) == readings.prefix(4).map(\.title.identifier.description))
        #expect(s.profile == "Alex")
        #expect(s.multipleProfiles)
        for (entry, reading) in zip(s.entries, readings) {
            #expect(Deeplink(entry.link) == .read(reading.title.identifier))
            #expect(entry.kind.rawValue == reading.title.kind.rawValue)
            #expect(abs(entry.fraction - reading.state.fraction) < 0.0001)
            #expect(entry.state != nil)
        }
    }

    @Test("Manga are named by series and carry the volume, books the author")
    func sublines() async throws {
        let shelf = await shelf()
        let s = ContinueReadingSnapshot.from(shelf.continueReading, profile: "M", multipleProfiles: false)
        let manga = try #require(s.entries.first { $0.kind == .manga })
        let original = try #require(shelf.continueReading.first { $0.title.kind == .manga })
        #expect(manga.name == original.title.series?.name)
        #expect(manga.subline == original.title.series?.volume.map { Formats.volume($0) })
        let book = try #require(s.entries.first { $0.kind == .book })
        let bookOriginal = try #require(shelf.continueReading.first { $0.title.kind == .book })
        #expect(book.name == bookOriginal.title.name)
        #expect(book.subline == bookOriginal.title.authors.first)
    }

    @Test("Cover paths: only whoever has a cover gets a file name, stable per identifier")
    func coverPaths() {
        let with = reading("a", fraction: 0.5, before: 10)
        let without = reading("b", fraction: 0.5, before: 20, cover: false)
        let s = ContinueReadingSnapshot.from([with, without], profile: "M", multipleProfiles: false)
        #expect(
            s.entries[0].cover
                == ContinueReadingSnapshot.coverFilename(for: "grimmory@buecher.example/a"))
        #expect(s.entries[1].cover == nil)
    }

    @Test("The empty snapshot comes with an empty row")
    func empty() {
        let s = ContinueReadingSnapshot.from([], profile: "Kim", multipleProfiles: true)
        #expect(s.entries.isEmpty)
        #expect(
            s == ContinueReadingSnapshot.empty(profile: "Kim", multipleProfiles: true).with(date: s.written)
        )
    }

    @Test("The writer puts JSON in the folder, without network only without covers")
    func writer() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "widget-ordner-\(UUID().uuidString)")
        let writer = SnapshotWriter(folder: folder, imageLoader: ImageLoader(folder: nil))
        let job = SnapshotWriter.Job(
            readings: [reading("a", fraction: 0.5, before: 10, cover: false)], profile: "Alex",
            multipleProfiles: false)
        let transport = MockTransport()
        writer.schedule(
            job,
            sources: SnapshotWriter.SourceAccess(
                headerLines: { _ in [:] }, transport: { _ in transport }))
        await writer.immediately()
        let read = try #require(SnapshotStore.load(from: folder))
        #expect(read.entries.map(\.id) == ["grimmory@buecher.example/a"])
        #expect(read.profile == "Alex")
    }

    @Test("Handoff: the activity carries title and link, and the link comes back as a deep link")
    func handoff() throws {
        let title = reading("42", fraction: 0.2, before: 0).title
        let activity = NSUserActivity(activityType: ReadingHandoff.kind)
        ReadingHandoff.fill(activity, with: title)
        #expect(activity.title == title.name)
        #expect(activity.isEligibleForHandoff)
        #expect(!activity.isEligibleForSearch)
        #expect(
            activity.userInfo?[ReadingHandoff.linkKey] as? String
                == "akari://lesen/grimmory/buecher.example/42")
        #expect(ReadingHandoff.link(from: activity) == .read(title.identifier))
    }

    @Test("Handoff: foreign and empty activities stay out")
    func foreignActivity() {
        let foreign = NSUserActivity(activityType: "dev.ms-solutions.akari.anderes")
        foreign.addUserInfoEntries(from: [
            ReadingHandoff.linkKey: "akari://lesen/grimmory/buecher.example/1"
        ])
        #expect(ReadingHandoff.link(from: foreign) == nil)
        let empty = NSUserActivity(activityType: ReadingHandoff.kind)
        #expect(ReadingHandoff.link(from: empty) == nil)
    }
}

extension ContinueReadingSnapshot {
    /// The same snapshot with another date, for comparison in the test.
    fileprivate func with(date: Date) -> ContinueReadingSnapshot {
        ContinueReadingSnapshot(
            profile: profile, multipleProfiles: multipleProfiles, entries: entries, written: date)
    }
}
