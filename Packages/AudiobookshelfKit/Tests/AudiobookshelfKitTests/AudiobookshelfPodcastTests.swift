import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import AudiobookshelfKit

/// Checked against a real Audiobookshelf instance: a second library of type
/// `podcast` with one podcast (Moonlit Tales, two episodes via Podsync), no state.
@Suite("AudiobookshelfQuelle · Podcasts (E54)")
struct AudiobookshelfPodcastTests {
    let server = URL(string: "https://hoerbuch.example")!
    let books = "eda12180-b631-4b53-b38d-f80bfd8c75e1"
    let podcasts = "5c96f269-169a-4608-8e0b-5c2f12c60a8d"
    let moonlit = "4a0859ec-3b82-47a8-96ca-043776bdc9dc"
    let episode1 = "db596d11-274e-4970-ba4a-8ffa94fa3ef5"

    private func source(_ t: MockTransport) -> AudiobookshelfSource {
        AudiobookshelfSource(
            account: AudiobookshelfAccount(
                server: server, userId: "c0b03793", username: "leser", token: "tok", mayFetch: true),
            transport: t)
    }

    private func withLibraries(_ t: MockTransport) throws {
        try t.answer("GET", "/api/libraries", file: "libraries-podcasts.json", from: .module)
        try t.answer("GET", "/api/libraries/\(books)/items", file: "items.json", from: .module)
        try t.answer("GET", "/api/libraries/\(podcasts)/items", file: "podcast-items.json", from: .module)
        try t.answer("GET", "/api/items/\(moonlit)", file: "podcast-item.json", from: .module)
        try t.answer("GET", "/api/me", file: "me-podcasts.json", from: .module)
    }

    @Test("The podcast library: one title per episode, the podcast is the series, one fetch per podcast")
    func library() async throws {
        let t = MockTransport()
        try withLibraries(t)
        let q = source(t)
        let extract = try await q.library()
        let episodeList = extract.title.filter { $0.kind == .podcast }
        #expect(extract.title.count == 15, "13 Hörbücher + 2 Folgen")
        #expect(episodeList.count == 2)
        #expect(
            t.paths == [
                "GET /api/libraries", "GET /api/libraries/\(books)/items",
                "GET /api/libraries/\(podcasts)/items", "GET /api/items/\(moonlit)", "GET /api/me",
            ])
        let series = try #require(extract.seriesList.first { $0.kind == .podcast })
        #expect(series.name == "Moonlit Tales Podcast")
        #expect(series.identifier.id == moonlit)
        #expect(series.volumeCount == 2)
        #expect(series.authors == ["Moonlit Tales"])
        // Volume 1 is the older episode — a lecture cycle is listened to in order.
        let ordered = episodeList.sorted { ($0.series?.volume ?? 0) < ($1.series?.volume ?? 0) }
        #expect(ordered[0].series?.volume == 1 && ordered[1].series?.volume == 2)
        #expect(ordered[0].released! < ordered[1].released!)
        let first = try #require(episodeList.first { $0.identifier.id == "\(moonlit):\(episode1)" })
        #expect(first.name.hasPrefix("Drio Lighthouse Keeper"))
        #expect(first.subtitle == nil, "Subtitle = title is none")
        #expect(first.series?.name == "Moonlit Tales Podcast")
        #expect(first.cover?.path() == "/api/items/\(moonlit)/cover")
        #expect(first.scope == .duration(3800.532))
        #expect(first.format == "MP3")
        #expect(first.size == 60_815_077)
        #expect(first.language == "tr")
        #expect(first.ageRating == 18, "the feed says explicit — what ABS makes of it, the app shows")
        #expect(first.summary?.hasPrefix("An invented description") == true)
        #expect(first.added == first.released, "“New on the shelf” means the episode's release")
    }

    @Test(
        "An episode's volume is its file; state goes through the episode path, forgetting through the entry id"
    )
    func volumeAndState() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/items/\(moonlit)", file: "podcast-item.json", from: .module)
        t.answer(
            "GET", "/api/me/progress/\(moonlit)/\(episode1)",
            with: .json(
                #"{"id":"x","libraryItemId":"\#(moonlit)","episodeId":"\#(episode1)","duration":3800.532,"progress":0.5,"currentTime":1900.2,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":1790010000000,"startedAt":1790009000000,"finishedAt":null}"#
            ))
        t.answer("PATCH", "/api/me/progress/\(moonlit)/\(episode1)", with: .json("{}"))
        t.answer("DELETE", "/api/me/progress/x", with: .json("{}"))
        let q = source(t)
        let identifier = TitleID(source: q.identifier, id: "\(moonlit):\(episode1)")

        let volume = try await q.audioManifest(identifier)
        #expect(volume.tracks.count == 1)
        #expect(volume.tracks[0].address.path() == "/api/items/\(moonlit)/file/4528236")
        #expect(volume.tracks[0].startTime == 0 && volume.tracks[0].duration == 3800.532)
        #expect(volume.tracks[0].fileExtension == "mp3")
        #expect(volume.duration == 3800.532)
        #expect(volume.chapter.isEmpty)

        let title = try await q.title(identifier)
        #expect(title.kind == .podcast && title.identifier == identifier)

        let state = try #require(try await q.progress(identifier))
        guard case .second(let s, let from) = state.position else {
            Issue.record("Seconds expected")
            return
        }
        #expect(abs(s - 1900.2) < 0.01 && abs(from - 3800.532) < 0.01)
        try await q.write(
            ReadingState(position: .second(2000, from: 3800.532), timestamp: Date(), completed: false),
            for: identifier)
        try await q.forget(progressFor: identifier)
        #expect(
            t.paths.suffix(4) == [
                "GET /api/me/progress/\(moonlit)/\(episode1)",
                "PATCH /api/me/progress/\(moonlit)/\(episode1)",
                "GET /api/me/progress/\(moonlit)/\(episode1)",
                "DELETE /api/me/progress/x",
            ])
        // An audiobook keeps the old path — its id has no colon.
        #expect(AudiobookshelfMapping.episodeParts("b5870c20") == nil)
        #expect(AudiobookshelfMapping.episodeParts("a:b")?.episodeItem == "b")
    }

    @Test("An episode's state from /api/me lands on the episode, not on the podcast")
    func stateFromMe() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/libraries", file: "libraries-podcasts.json", from: .module)
        try t.answer("GET", "/api/libraries/\(books)/items", file: "items.json", from: .module)
        try t.answer("GET", "/api/libraries/\(podcasts)/items", file: "podcast-items.json", from: .module)
        try t.answer("GET", "/api/items/\(moonlit)", file: "podcast-item.json", from: .module)
        t.answer(
            "GET", "/api/me",
            with: .json(
                #"{"id":"c0b03793","username":"leser","token":"tok","mediaProgress":[{"id":"y","libraryItemId":"\#(moonlit)","episodeId":"\#(episode1)","duration":3800.532,"progress":0.1,"currentTime":380,"isFinished":false,"lastUpdate":1790010000000}],"permissions":{"download":true}}"#
            ))
        let q = source(t)
        let extract = try await q.library()
        #expect(extract.readingStates.count == 1)
        #expect(extract.readingStates.keys.first?.id == "\(moonlit):\(episode1)")
    }

    @Test(
        "The latest episodes: one fetch per podcast library, arrival instead of release, books are left out"
    )
    func latestEpisodes() async throws {
        let t = MockTransport()
        try t.answer("GET", "/api/libraries", file: "libraries-podcasts.json", from: .module)
        try t.answer(
            "GET", "/api/libraries/\(podcasts)/recent-episodes", file: "podcast-recent.json", from: .module)
        let q = source(t)
        let episodeList = try await q.latestEpisodes()
        #expect(t.paths == ["GET /api/libraries", "GET /api/libraries/\(podcasts)/recent-episodes"])
        #expect(t.requests.last?.url?.query()?.contains("limit=50") == true)
        #expect(episodeList.count == 3)
        let first = try #require(episodeList.first)
        #expect(first.podcastName == "Glireis ko Lefreru")
        #expect(
            first.identifier.id == "bb35dcfe-665b-4a4c-ae49-8fdb0500d6e6:dfd34ec4-906e-4089-98de-992d442190bd"
        )
        #expect(first.podcast == SeriesID(source: q.identifier, id: "bb35dcfe-665b-4a4c-ae49-8fdb0500d6e6"))
        #expect(first.arrived == Date(timeIntervalSince1970: 1_790_136_148.948))
        // The Moonlit Tales episode was released before the second one, but arrived later.
        #expect(episodeList[2].arrived > episodeList[1].arrived)
    }
}
