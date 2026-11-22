import Foundation
import Testing

@testable import WidgetBridge

@Suite("Schnappschuss „Weiterhören\"")
struct ContinueListeningSnapshotTests {

    private let link = URL(string: "akari://lesen/audiobookshelf/hoerbuch.example/li_1")!
    private let written = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(
        running: Bool, tempo: Double = 1, time: TimeInterval = 3_600
    )
        -> ContinueListeningSnapshot
    {
        ContinueListeningSnapshot(
            profile: "Alex", multipleProfiles: true,
            audiobook: ContinueListeningSnapshot.Audiobook(
                id: "audiobookshelf@hoerbuch.example/li_1", name: "Frankenstein", subline: "Mary Shelley",
                chapter: "Kapitel 4", time: time, duration: 10_000, tempo: tempo, running: running,
                link: link,
                cover: ContinueReadingSnapshot.coverFilename(for: "audiobookshelf@hoerbuch.example/li_1")),
            written: written)
    }

    @Test("When stopped, the position stays as it was")
    func whileStopped() {
        let s = snapshot(running: false)
        let later = written.addingTimeInterval(600)
        #expect(s.time(asOf: later) == 3_600)
        #expect(s.remainder(asOf: later) == 6_400)
        #expect(abs(s.fraction(asOf: later) - 0.36) < 0.0001)
        #expect(s.end(from: later) == nil)
    }

    @Test("When playing, the position advances at the pace — up to the end, never beyond")
    func running() throws {
        let s = snapshot(running: true, tempo: 1.5)
        let later = written.addingTimeInterval(600)
        #expect(s.time(asOf: later) == 3_600 + 900)
        #expect(s.remainder(asOf: later) == 10_000 - 4_500)
        #expect(s.time(asOf: written.addingTimeInterval(-60)) == 3_600)
        #expect(s.time(asOf: written.addingTimeInterval(100_000)) == 10_000)
        #expect(s.remainder(asOf: written.addingTimeInterval(100_000)) == 0)
        let end = try #require(s.end(from: written))
        #expect(abs(end.timeIntervalSince(written) - 6_400 / 1.5) < 0.01)
    }

    @Test("Limits: position and duration stay at 0 or above, a pace of 0 becomes 1")
    func limits() {
        let h = ContinueListeningSnapshot.Audiobook(
            id: "x", name: "X", subline: nil, chapter: nil, time: -5, duration: -1, tempo: 0, running: true,
            link: link, cover: nil)
        #expect(h.time == 0)
        #expect(h.duration == 0)
        #expect(h.tempo == 1)
        let s = ContinueListeningSnapshot(profile: "M", audiobook: h)
        #expect(s.fraction(asOf: Date()) == 0)
        #expect(ContinueListeningSnapshot.empty(profile: "M").audiobook == nil)
    }

    @Test("Writing and reading with cover — a second write without a book removes the cover")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hoeren-\(UUID().uuidString)")
        let s = snapshot(running: true)
        let cover = try #require(s.audiobook?.cover)
        try SnapshotStore.writeContinueListening(s, cover: [cover: Data([1, 2])], in: folder)
        let read = try #require(SnapshotStore.readContinueListening(from: folder))
        #expect(read.audiobook == s.audiobook)
        #expect(read.multipleProfiles)
        #expect(abs(read.written.timeIntervalSince(written)) < 1)
        let path = try #require(SnapshotStore.cover(read.audiobook!, in: folder))
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(SnapshotStore.existingCovers(in: folder) == [cover])
        try SnapshotStore.writeContinueListening(.empty(profile: "Alex"), cover: [:], in: folder)
        #expect(SnapshotStore.existingCovers(in: folder).isEmpty)
        #expect(SnapshotStore.readContinueListening(from: folder)?.audiobook == nil)
    }
}
