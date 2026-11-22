import Foundation
import SourcesKit
import Testing

@testable import AudioPlayer

@Suite("Play rules")
struct PlayRulesTests {

    private let volume = AudioManifest(
        tracks: [
            AudioTrack(address: URL(string: "https://x/1")!, startTime: 0, duration: 100),
            AudioTrack(address: URL(string: "https://x/2")!, startTime: 100, duration: 100),
            AudioTrack(address: URL(string: "https://x/3")!, startTime: 200, duration: 50),
        ],
        chapter: [
            Chapter(name: "Eins", startTime: 0, end: 80), Chapter(name: "Zwei", startTime: 80, end: 180),
            Chapter(name: "Drei", startTime: 180, end: 250),
        ])

    @Test("Smart rewind: 0 / 3 / 10 / 20 / 30 seconds")
    func rewind() {
        #expect(PlayRules.rewind(afterPause: 2) == 0)
        #expect(PlayRules.rewind(afterPause: 30) == 3)
        #expect(PlayRules.rewind(afterPause: 5 * 60) == 10)
        #expect(PlayRules.rewind(afterPause: 30 * 60) == 20)
        #expect(PlayRules.rewind(afterPause: 3 * 3600) == 30)
    }

    @Test("Local or stream: files directly, server via the bridge, without a bridge nothing")
    func address() {
        let bridge: (Int) -> URL = { URL(string: "http://127.0.0.1:1/spur/\($0)")! }
        #expect(
            PlayRules.address(track: 1, in: volume, bridge: bridge)?.absoluteString
                == "http://127.0.0.1:1/spur/1")
        #expect(PlayRules.address(track: 1, in: volume, bridge: nil) == nil)
        #expect(PlayRules.address(track: 3, in: volume, bridge: bridge) == nil)
        let local = AudioManifest(
            tracks: volume.tracks.enumerated().map { i, s in
                s.with(address: URL(filePath: "/tmp/spur-\(i).mp3"))
            },
            chapter: volume.chapter)
        #expect(local.local && !volume.local)
        #expect(local.duration == volume.duration)
        #expect(PlayRules.address(track: 2, in: local, bridge: bridge) == URL(filePath: "/tmp/spur-2.mp3"))
        #expect(PlayRules.address(track: 2, in: local, bridge: nil) == URL(filePath: "/tmp/spur-2.mp3"))
        // Mixed stays one stream: a track from the server means bridge.
        let mixed = AudioManifest(tracks: [local.tracks[0], volume.tracks[1]], chapter: [])
        #expect(!mixed.local)
    }

    @Test("Track and chapter at a time, also at the edges")
    func layout() {
        #expect(PlayRules.track(for: 0, in: volume) == 0)
        #expect(PlayRules.track(for: 100, in: volume) == 1)
        #expect(PlayRules.track(for: 249, in: volume) == 2)
        #expect(PlayRules.track(for: 999, in: volume) == 2)
        #expect(PlayRules.chapter(for: 79.9, in: volume) == 0)
        #expect(PlayRules.chapter(for: 80, in: volume) == 1)
        #expect(PlayRules.chapter(for: 250, in: volume) == 2)
        #expect(PlayRules.track(for: 1, in: AudioManifest(tracks: [], chapter: [])) == nil)
    }

    @Test("Back with chapter threshold: at the start to the previous one, otherwise to the start")
    func back() {
        #expect(PlayRules.previousChapter(from: 81, in: volume) == 0)
        #expect(PlayRules.previousChapter(from: 120, in: volume) == 80)
        #expect(PlayRules.previousChapter(from: 1, in: volume) == 0)
        #expect(PlayRules.nextChapter(from: 120, in: volume) == 180)
        #expect(PlayRules.nextChapter(from: 200, in: volume) == nil)
    }

    @Test("Finished in the last five seconds; clock formatted")
    func remainder() {
        #expect(PlayRules.finished(246, duration: 250))
        #expect(!PlayRules.finished(240, duration: 250))
        #expect(PlayRules.clock(59) == "0:59")
        #expect(PlayRules.clock(3725) == "1:02:05")
    }

    @Test("Defaults: 30 / 15 / 1.0 and the last sleep choice stays")
    @MainActor
    func presets() {
        let name = "spieler-\(UUID().uuidString)"
        let persistence = UserDefaults(suiteName: name)!
        let v = PlayDefaults(persistence: persistence)
        #expect(v.jumpForward == 30 && v.jumpBack == 15 && v.tempo == 1.0 && v.sleep == nil)
        v.sleep = .chapterEnd
        v.tempo = 1.5
        v.jumpForward = 45
        let new = PlayDefaults(persistence: persistence)
        #expect(new.sleep == .chapterEnd && new.tempo == 1.5 && new.jumpForward == 45)
        new.sleep = .minutes(15)
        #expect(PlayDefaults(persistence: persistence).sleep == .minutes(15))
        persistence.removePersistentDomain(forName: name)
    }
}

/// The player sheet on iPad: core 600 pt, cover 520 - narrow stays 420, AX 240.
@Suite("Player metrics per size class")
@MainActor
struct PlayerMetricsTests {

    @Test("Cover cap: narrow 420, wide 520, accessibility 240 everywhere")
    func cover() {
        #expect(AudioPlayerView.coverCap(wide: false, large: false) == 420)
        #expect(AudioPlayerView.coverCap(wide: true, large: false) == 520)
        #expect(AudioPlayerView.coverCap(wide: true, large: true) == 240)
        #expect(AudioPlayerView.coverCap(wide: false, large: true) == 240)
        #expect(AudioPlayerView.coreWidth == 600)
    }
}
