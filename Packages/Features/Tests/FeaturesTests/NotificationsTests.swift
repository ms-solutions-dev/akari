import Foundation
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Features

/// A messenger that delivers nothing but records, and grants permission as configured.
@MainActor
final class Mailbox: NotificationSender {
    var isAllowed: Bool
    private(set) var delivered: [EpisodeNotice] = []
    private(set) var asked = 0

    init(isAllowed: Bool = true) { self.isAllowed = isAllowed }

    func allow() async -> Bool {
        asked += 1
        return isAllowed
    }

    func allowed() async -> Bool { isAllowed }

    func spot(_ messages: [EpisodeNotice]) async { delivered += messages }
}

/// Reporting new podcast episodes: the choice per profile, the watcher, the path through the core.
@Suite("Notifications about new episodes")
@MainActor
struct NotificationsTests {

    let source = SourceID(provider: .audiobookshelf, server: "podcasts.example")
    var podcastA: SeriesID { SeriesID(source: source, id: "li_a") }
    var podcastB: SeriesID { SeriesID(source: source, id: "li_b") }

    func episode(_ podcast: SeriesID, _ nr: Int, _ arrived: Date) -> NewAddition {
        NewAddition(
            identifier: TitleID(source: source, id: "\(podcast.id):ep_\(nr)"), podcast: podcast,
            podcastName: "Podcast \(podcast.id)", name: "Folge \(nr)", arrived: arrived)
    }

    @Test("The choice survives a restart; enabling and subscribing count from now on, moving only forward")
    func choice() {
        let name = "mitteilungen-\(UUID().uuidString)"
        let persistence = UserDefaults(suiteName: name)!
        defer { persistence.removePersistentDomain(forName: name) }
        let yesterday = Date(timeIntervalSinceNow: -86_400)
        let now = Date()

        let choice = NotificationChoice(persistence: persistence)
        #expect(!choice.to && choice.subscriptions.isEmpty)
        choice.subscribe(podcastA, true, now: yesterday)
        choice.subscribe(podcastA, true, now: now)
        #expect(
            choice.subscriptions[podcastA] == yesterday, "a second subscribe does not reset the state")
        choice.advance([podcastA: yesterday.addingTimeInterval(-60), podcastB: now])
        #expect(choice.subscriptions[podcastA] == yesterday, "not backward")
        #expect(choice.subscriptions[podcastB] == nil, "no subscription through the back door")

        choice.switchTo(true, now: now)
        #expect(choice.to && choice.subscriptions[podcastA] == now, "Enabling: no flood from before")

        let reloaded = NotificationChoice(persistence: persistence)
        #expect(reloaded.to && reloaded.subscriptions == [podcastA: now])
        reloaded.subscribe(podcastA, false)
        #expect(NotificationChoice(persistence: persistence).subscriptions.isEmpty)
    }

    @Test("Only what arrived after a subscription's state is new; one notification per podcast")
    func watcher() {
        let state = Date(timeIntervalSince1970: 1_000_000)
        let episodes = [
            episode(podcastA, 1, state.addingTimeInterval(-10)),
            episode(podcastA, 2, state.addingTimeInterval(10)),
            episode(podcastA, 3, state.addingTimeInterval(20)),
            episode(podcastB, 1, state.addingTimeInterval(30)),
            episode(SeriesID(source: source, id: "li_c"), 1, state.addingTimeInterval(40)),
        ]
        let new = EpisodeWatcher.new(episodes, subscriptions: [podcastA: state, podcastB: state])
        #expect(new.map(\.name) == ["Folge 2", "Folge 3", "Folge 1"])
        #expect(EpisodeWatcher.seen(episodes)[podcastA] == state.addingTimeInterval(20))

        let messages = EpisodeWatcher.messages(new)
        #expect(messages.count == 2)
        // B arrived last and comes first: one episode, the link points to it.
        #expect(messages[0].title == "Podcast li_b" && messages[0].text == "Folge 1")
        #expect(messages[0].link == Deeplink.title(episodes[3].identifier).url)
        // A: two episodes, one notification; the link points to the podcast, the newest is in the text.
        #expect(messages[1].text.hasSuffix(" · Folge 3"))
        #expect(messages[1].link == Deeplink.series(podcastA).url)
        #expect(messages[1].thread == "podcast-\(podcastA)")
        #expect(messages[1].identifier == "folge-\(episodes[2].identifier)")
    }

    @Test("Through the core: subscribe, report nothing old, report a new episode once")
    func core() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let podcasts = MockShelf.podcasts()
        let core = AppCore(
            profiles: state.profiles,
            context: { profile, persistence, device in
                state.context(profile, persistence, device, sources: { [podcasts] })
            },
            device: state.device, preview: true)
        let box = Mailbox()
        core.sender = box
        let choice = core.context.notifications
        let moonlit = try #require(podcasts.extract.seriesList.first).identifier

        // Main switch off: nothing.
        choice.subscribe(moonlit, true)
        await core.checkEpisodes()
        #expect(box.delivered.isEmpty)

        choice.switchTo(true)
        await core.checkEpisodes()
        #expect(box.delivered.isEmpty, "the mock's four episodes are older than the subscription")

        let new = NewAddition(
            identifier: TitleID(source: podcasts.identifier, id: "li_p1:ep_5"), podcast: moonlit,
            podcastName: "Moonlit Tales Podcast", name: "Sabır", arrived: Date().addingTimeInterval(60))
        podcasts.newAdditions.append(new)
        await core.checkEpisodes()
        #expect(box.delivered.map(\.text) == ["Sabır"])
        await core.checkEpisodes()
        #expect(box.delivered.count == 1, "the same episode not twice")

        // Without the system's permission: no query to the server.
        box.isAllowed = false
        podcasts.newAdditions.append(
            NewAddition(
                identifier: TitleID(source: podcasts.identifier, id: "li_p1:ep_6"), podcast: moonlit,
                podcastName: "Moonlit Tales Podcast", name: "Şükür", arrived: Date().addingTimeInterval(120)
            ))
        await core.checkEpisodes()
        #expect(box.delivered.count == 1)
    }

    @Test("A server that does not answer drops out silently, its state stays")
    func unreachable() async throws {
        let state = ProfileState()
        defer { state.tidyUp() }
        let podcasts = MockShelf.podcasts()
        let core = AppCore(
            profiles: state.profiles,
            context: { profile, persistence, device in
                state.context(profile, persistence, device, sources: { [podcasts] })
            },
            device: state.device, preview: true)
        let box = Mailbox()
        core.sender = box
        let choice = core.context.notifications
        let moonlit = try #require(podcasts.extract.seriesList.first).identifier
        choice.switchTo(true)
        choice.subscribe(moonlit, true)
        let previously = choice.subscriptions[moonlit]

        podcasts.set(network: .unreachable)
        podcasts.newAdditions.append(
            NewAddition(
                identifier: TitleID(source: podcasts.identifier, id: "li_p1:ep_5"), podcast: moonlit,
                podcastName: "Moonlit Tales Podcast", name: "Sabır", arrived: Date().addingTimeInterval(60))
        )
        await core.checkEpisodes()
        #expect(box.delivered.isEmpty && choice.subscriptions[moonlit] == previously)

        podcasts.set(network: .reachable)
        await core.checkEpisodes()
        #expect(box.delivered.map(\.text) == ["Sabır"], "what arrived in the meantime arrives later at home")
    }
}
