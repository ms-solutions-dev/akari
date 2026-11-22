import AccountsKit
import Bedrock
import DesignSystem
import Foundation
import Library
import OfflineStore
import SourcesKit
import SourcesKitMocks
import SwiftUI
import Testing

@testable import Features

/// The disruption pass in the shell: the probe is read correctly, a fetch failure gets a
/// sentence from the catalog, and the shell knows by name what the store left behind.
@Suite("Disruptions in the shell")
@MainActor
struct DisruptionShellTests {

    @Test("The probe reads `stoerung:<case>`, anything else is none")
    func probe() {
        #expect(DisruptionProbe.from("stoerung:komga-aus") == .komgaOff)
        #expect(DisruptionProbe.from("stoerung:401") == .expired)
        #expect(DisruptionProbe.from("stoerung:502") == .serverDisruption)
        #expect(DisruptionProbe.from("stoerung:langsam-start") == .slowStart)
        #expect(DisruptionProbe.from("stoerung:gibtsnicht") == nil)
        #expect(DisruptionProbe.from("lesen") == nil)
        #expect(DisruptionProbe.from(nil) == nil)
        #expect(DisruptionProbe.download.opens == "serie")
        #expect(DisruptionProbe.pages.opens == nil)
        #expect(DisruptionProbe.allCases.count == 14)
    }

    @Test("The probe sets up the mocks: extracts in persistence, source off, 401, 502, certificate question")
    func configure() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let sources = MockShelf.base()
        let questions = CertificateQuestion()
        let persistence = LibraryStore(folder: folder)
        DisruptionProbe.komgaOff.configure(
            sources: sources, transport: MockTransport(), questions: questions, persistence: persistence)
        #expect(
            persistence.loadExtract(sources[0].identifier)?.title.count == 3,
            "the start comes from the cache")
        await #expect(throws: SourceError.unreachable(sources[0].identifier)) {
            try await sources[0].verify()
        }
        try await sources[1].verify()

        let fresh = MockShelf.base()
        DisruptionProbe.expired.configure(
            sources: fresh, transport: MockTransport(), questions: questions, persistence: persistence)
        await #expect(throws: SourceError.signedOut(fresh[0].identifier)) { try await fresh[0].verify() }

        DisruptionProbe.certificate.configure(
            sources: MockShelf.base(), transport: MockTransport(), questions: questions,
            persistence: persistence)
        #expect(questions.present?.host == "comics.example")
        #expect(questions.present?.known != nil, "a CHANGED certificate, not an unknown one")
    }

    @Test("A fetch failure gets its sentence: status from the file fetcher, URLError as unreachable")
    func fetchFailure() {
        let k = SourceID(provider: .grimmory, server: "buecher.example")
        let title = TitleID(source: k, id: "7")
        #expect(SourceError.onFetch(FileFetcher.Failure.status(401), source: k) == .signedOut(k))
        #expect(
            SourceError.onFetch(FileFetcher.Failure.status(502), source: k)
                == .serverDisruption(k, status: 502))
        #expect(
            SourceError.onFetch(FileFetcher.Failure.status(404), source: k, title: title)
                == .notFound(title))
        #expect(SourceError.onFetch(URLError(.notConnectedToInternet), source: k) == .unreachable(k))
        #expect(SourceError.onFetch(SourceError.denied(k), source: k) == .denied(k))
        #expect(SourceError.unreachable(k).glyph == "wifi.exclamationmark")
        #expect(SourceError.signedOut(k).glyph == "person.crop.circle.badge.exclamationmark")
        #expect(!SourceError.unreachable(k).final, "Try again makes sense")
        #expect(SourceError.signedOut(k).final, "not here, the button is missing")
    }

    @Test("What the store left behind is in `unterbrochene`, finished and running items are not")
    func interrupted() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorrat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = KeepStore(folder: folder)
        let k = SourceID(provider: .komga, server: "comics.example")
        let a = TitleID(source: k, id: "a")
        let b = TitleID(source: k, id: "b")
        let c = TitleID(source: k, id: "c")
        try persistence.write([
            KeptItem(
                identifier: a, name: "A", kind: .manga, since: Date(), size: 10,
                state: .ongoing(fraction: 0.3, bytes: 10), files: []),
            KeptItem(
                identifier: b, name: "B", kind: .manga, since: Date(), size: 99, state: .done,
                files: ["seite-0001"]),
            KeptItem(
                identifier: c, name: "C", kind: .book, since: Date(), size: 5, state: .disrupted("Netz"),
                files: []),
        ])
        let service = StockService(persistence: persistence)
        // What was running at quit is "interrupted" at launch, and gets resumed.
        #expect(Set(service.interrupted) == [a, c])
        #expect(service.completed == [b])
    }

    @Test("The certificate state is red and disrupted")
    func certificateColor() {
        #expect(AccountRow.signal(.certificate) == .failure)
        #expect(AccountState.certificate.needsAttention)
    }
}
