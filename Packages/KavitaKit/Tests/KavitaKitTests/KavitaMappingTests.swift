import Foundation
import SourcesKit
import Testing

@testable import KavitaKit

/// The translations without a server: time, reading state in both directions, rating, stars.
@Suite("KavitaAbbildung")
struct KavitaMappingTests {

    @Test("Kavita time: seven fractional digits, no zone — counts as UTC; 0001 means never")
    func time() throws {
        let date = try #require(KavitaResponses.time("2026-10-24T19:57:46.2061477"))
        #expect(abs(date.timeIntervalSince1970 - 1_792_871_866.2061477) < 0.001)
        #expect(KavitaResponses.time("2026-10-24T19:57:46Z") == Date(timeIntervalSince1970: 1_792_871_866))
        #expect(
            KavitaResponses.time("2026-10-24T21:57:46+02:00") == Date(timeIntervalSince1970: 1_792_871_866),
            "a zone is subtracted")
        let never = try #require(KavitaResponses.time("0001-01-01T00:00:00"))
        #expect(KavitaMapping.realDate(never) == nil)
        #expect(KavitaResponses.time("gestern") == nil)
    }

    @Test("Pages: pageNum counts from 0, the page number itself means read, 0 means never started")
    func pageState() throws {
        #expect(KavitaMapping.readingState(page: 0, pages: 20, epub: false, time: nil) == nil)
        #expect(KavitaMapping.readingState(page: nil, pages: 20, epub: false, time: nil) == nil)
        let middle = try #require(KavitaMapping.readingState(page: 4, pages: 20, epub: false, time: nil))
        #expect(middle.position == .page(5, from: 20))
        #expect(!middle.completed)
        let done = try #require(KavitaMapping.readingState(page: 20, pages: 20, epub: false, time: nil))
        #expect(done.position == .page(20, from: 20))
        #expect(done.completed)
        // And back: page 5 from Akari is pageNum 4, done is the page count.
        #expect(KavitaMapping.pageNumber(middle, pages: 20) == 4)
        #expect(KavitaMapping.pageNumber(done, pages: 20) == 20)
        #expect(
            KavitaMapping.pageNumber(
                ReadingState(position: .page(1, from: 20), timestamp: Date()), pages: 20)
                == 0)
    }

    @Test("EPUB: the fraction of sections; a CFI becomes the section its fraction falls in")
    func epubState() throws {
        let state = try #require(KavitaMapping.readingState(page: 79, pages: 317, epub: true, time: nil))
        #expect(state.position == .fraction(79.0 / 317.0))
        let read = ReadingState(
            position: .position(cfi: "epubcfi(/6/4!/4/2)", fraction: 0.5), timestamp: Date())
        #expect(KavitaMapping.pageNumber(read, pages: 317) == 158)
        let done = ReadingState(position: .fraction(1), timestamp: Date(), completed: true)
        #expect(KavitaMapping.pageNumber(done, pages: 317) == 317)
        let end = ReadingState(position: .fraction(1), timestamp: Date())
        #expect(
            KavitaMapping.pageNumber(end, pages: 317) == 316, "not finished means: not the page count"
        )
    }

    @Test("Age rating: Kavita's levels in years; unknown and pending are none")
    func sharing() {
        #expect(KavitaMapping.ageRating(0) == nil)
        #expect(KavitaMapping.ageRating(1) == nil)
        #expect(KavitaMapping.ageRating(-1) == nil)
        #expect(KavitaMapping.ageRating(nil) == nil)
        #expect(KavitaMapping.ageRating(3) == 0)
        #expect(KavitaMapping.ageRating(8) == 13)
        #expect(KavitaMapping.ageRating(9) == 15)
        #expect(KavitaMapping.ageRating(14) == 18)
    }

    @Test("Stars from all accounts: percent to five, origin Kavita; nobody rated means none")
    func stars() throws {
        #expect(
            KavitaMapping.rating(.init(averageScore: 0, favoriteCount: 0, provider: 0)) == nil)
        let four = try #require(
            KavitaMapping.rating(.init(averageScore: 80, favoriteCount: 1, provider: 0)))
        #expect(four.stars == 4)
        #expect(four.origin == "Kavita")
        #expect(
            KavitaMapping.rating(.init(averageScore: 70, favoriteCount: 0, provider: 1))?.origin
                == "AniList", "what Kavita+ fetches is named after its source")
    }

    @Test(
        "Reading direction from the reading profile: series before library before default; webtoon scrolls vertically"
    )
    func readingProfile() {
        let preset = KavitaResponses.ReadingProfile(
            id: 1, kind: 0, seriesIds: [], libraryIds: [], readingDirection: 0, readerMode: 0,
            allowAutomaticWebtoonReaderDetection: false)
        let manga = KavitaResponses.ReadingProfile(
            id: 2, kind: 1, seriesIds: [], libraryIds: [2], readingDirection: 1, readerMode: 0,
            allowAutomaticWebtoonReaderDetection: false)
        let webtoon = KavitaResponses.ReadingProfile(
            id: 3, kind: 1, seriesIds: [77], libraryIds: [], readingDirection: 0, readerMode: 2,
            allowAutomaticWebtoonReaderDetection: true)
        let all = [preset, manga, webtoon]
        func direction(_ series: Int, _ library: Int?) -> ReadingDirection? {
            KavitaMapping.readingDirection(
                KavitaMapping.readingProfile(all, series: series, library: library))
        }
        #expect(direction(77, 2) == .vertical, "the series beats the library")
        #expect(direction(5, 2) == .rightToLeft)
        #expect(direction(5, 3) == .leftToRight, "otherwise the default")
        #expect(KavitaMapping.readingDirection(nil) == nil)
    }

    @Test("Roles: download or admin means keep")
    func roles() {
        let server = URL(string: "https://kavita.example")!
        let reader = KavitaAccount(
            server: server, userId: 2, username: "leser", apiKey: "k", keyId: 7,
            roles: ["Login"])
        #expect(!reader.capabilities.contains(.keep))
        #expect(reader.capabilities.contains(.pageStream))
        #expect(reader.capabilities.contains(.savedList))
        let downloader = KavitaAccount(
            server: server, userId: 2, username: "leser", apiKey: "k", keyId: 7,
            roles: ["Login", "Download"])
        #expect(downloader.capabilities.contains(.keep))
        #expect(reader.identifier == SourceID(provider: .kavita, server: "kavita.example"))
    }
}
