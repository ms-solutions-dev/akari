import Foundation
import SourcesKit
import Testing
import WidgetBridge

@testable import Features

@Suite("Deep Links")
struct DeeplinkTests {

    let source = SourceID(provider: .grimmory, server: "buecher.example")

    @Test("Title, series, read, continue reading and statistics, there and back")
    func roundTrip() throws {
        let links: [Deeplink] = [
            .title(TitleID(source: source, id: "0HNM0-abc")),
            .series(
                SeriesID(
                    source: SourceID(provider: .komga, server: "comics.example:25600"), id: "x1")
            ),
            .read(
                TitleID(
                    source: SourceID(provider: .audiobookshelf, server: "hoerbuch.example"), id: "li_9")
            ),
            .continueReading,
            .statistics,
        ]
        for link in links {
            #expect(Deeplink(link.url) == link, "\(link.url)")
        }
    }

    @Test("The format is the documented one")
    func form() {
        let link = Deeplink.title(TitleID(source: source, id: "42"))
        #expect(link.url.absoluteString == "akari://titel/grimmory/buecher.example/42")
        #expect(Deeplink.continueReading.url.absoluteString == "akari://weiterlesen")
        #expect(Deeplink.statistics.url.absoluteString == "akari://statistik")
        #expect(Deeplink(SnapshotStore.statisticsLink) == .statistics)
    }

    @Test("Foreign links stay out: other scheme, setup, unknown provider, too short")
    func foreign() {
        let bad = [
            "https://titel/grimmory/buecher.example/42",
            "akari://einrichten?server=x",
            "akari://titel/plex/buecher.example/42",
            "akari://titel/grimmory/42",
            "akari://weiterlesen/extra",
            "akari://statistik/woche",
            "akari://serie/komga//1",
        ]
        for text in bad {
            #expect(Deeplink(URL(string: text)!) == nil, Comment(rawValue: text))
        }
    }
}
