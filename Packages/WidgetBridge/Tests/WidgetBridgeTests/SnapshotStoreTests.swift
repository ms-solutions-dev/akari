import Foundation
import Testing

@testable import WidgetBridge

@Suite("Schnappschuss „Weiterlesen\"")
struct SnapshotStoreTests {

    private func entry(
        _ id: String, fraction: Double = 0.3, cover: Bool = true
    )
        -> ContinueReadingSnapshot.Item
    {
        ContinueReadingSnapshot.Item(
            id: id, name: "Titel \(id)", subline: "Jemand", kind: .book, fraction: fraction,
            link: URL(string: "akari://lesen/grimmory/buecher.example/\(id)")!,
            cover: cover ? ContinueReadingSnapshot.coverFilename(for: id) : nil)
    }

    private func freshFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "schnappschuss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("The cap is four, and the fraction stays between 0 and 1")
    func cap() {
        let s = ContinueReadingSnapshot(
            profile: "Alex", entries: (1...6).map { entry("\($0)", fraction: Double($0) - 3) })
        #expect(s.entries.count == ContinueReadingSnapshot.cap)
        #expect(s.entries.map(\.id) == ["1", "2", "3", "4"])
        #expect(s.entries[0].fraction == 0)
        #expect(s.entries[3].fraction == 1)
    }

    @Test("Writing and reading — round trip, with date")
    func roundTrip() throws {
        let folder = try freshFolder()
        let s = ContinueReadingSnapshot(
            profile: "Sam", multipleProfiles: true, entries: [entry("a"), entry("b")])
        let coverA = try #require(s.entries[0].cover)
        try SnapshotStore.write(s, cover: [coverA: Data([1, 2, 3])], in: folder)
        let read = try #require(SnapshotStore.load(from: folder))
        #expect(read.profile == "Sam")
        #expect(read.multipleProfiles)
        #expect(read.entries == s.entries)
        #expect(abs(read.written.timeIntervalSince(s.written)) < 1)
        let path = try #require(SnapshotStore.cover(s.entries[0], in: folder))
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(SnapshotStore.existingCovers(in: folder) == [coverA])
    }

    @Test("A second write removes covers no entry names any more")
    func cleansUp() throws {
        let folder = try freshFolder()
        let a = entry("a")
        let b = entry("b")
        let coverA = try #require(a.cover)
        let coverB = try #require(b.cover)
        try SnapshotStore.write(
            ContinueReadingSnapshot(profile: "M", entries: [a, b]),
            cover: [coverA: Data([1]), coverB: Data([2])], in: folder)
        try SnapshotStore.write(
            ContinueReadingSnapshot(profile: "M", entries: [b]), cover: [:], in: folder)
        #expect(SnapshotStore.existingCovers(in: folder) == [coverB])
        #expect(SnapshotStore.load(from: folder)?.entries.map(\.id) == ["b"])
    }

    @Test("The empty snapshot is readable and empty")
    func empty() throws {
        let folder = try freshFolder()
        try SnapshotStore.write(.empty(profile: "Kim"), cover: [:], in: folder)
        let read = try #require(SnapshotStore.load(from: folder))
        #expect(read.entries.isEmpty)
        #expect(read.profile == "Kim")
    }

    @Test("Without a file no snapshot, no error")
    func missing() throws {
        #expect(SnapshotStore.load(from: try freshFolder()) == nil)
    }

    @Test("The cover filename is stable, file-safe and does not name the server")
    func filename() {
        let name = ContinueReadingSnapshot.coverFilename(for: "komga@comics.example:25600/0K3ABC")
        #expect(name == ContinueReadingSnapshot.coverFilename(for: "komga@comics.example:25600/0K3ABC"))
        #expect(name.hasSuffix(".jpg"))
        #expect(!name.contains("comics.example"))
        #expect(!name.contains("/"))
        #expect(name != ContinueReadingSnapshot.coverFilename(for: "komga@comics.example:25600/0K3ABD"))
    }
}
