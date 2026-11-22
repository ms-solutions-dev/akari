import Foundation
import ReadingProgress
import SourcesKit
import SourcesKitMocks
import Testing

@testable import Library

/// The server is the truth — and without network nothing is lost.
@Suite("Library: progress")
@MainActor
struct LibraryProgressTests {

    private func service() async -> (LibraryService, MockSource, Title) {
        let persistence = LibraryStore(
            folder: FileManager.default.temporaryDirectory.appending(path: "fortschritt-\(UUID().uuidString)")
        )
        let sources = MockShelf.base()
        let service = LibraryService(persistence: persistence, queue: Queue(folder: nil)) { sources }
        await service.refresh()
        let volume = service.shelf.allTitles.first {
            $0.kind == .manga && service.shelf.readingState($0.identifier) == nil
        }!
        return (service, sources[0], volume)
    }

    private func state(_ page: Int, before seconds: TimeInterval = 0, done: Bool = false) -> ReadingState {
        ReadingState(
            position: .page(page, from: 200), timestamp: Date().addingTimeInterval(-seconds),
            completed: done)
    }

    @Test(
        "Without network the state stays on the shelf and moves into the queue; with network it is resubmitted"
    )
    func queue() async throws {
        let (service, komga, volume) = await service()
        komga.set(network: .unreachable)
        try await service.write(state(40), for: volume.identifier)
        #expect(service.shelf.readingState(volume.identifier)?.position == .page(40, from: 200))
        #expect(service.pending == 1)
        #expect(komga.written.isEmpty)
        // A second state replaces the first in the queue.
        try await service.write(state(55), for: volume.identifier)
        #expect(service.pending == 1)

        // Refresh without network: the shelf keeps the pending state.
        await service.refresh()
        #expect(service.shelf.readingState(volume.identifier)?.position == .page(55, from: 200))

        komga.set(network: .reachable)
        await service.refresh()
        #expect(service.pending == 0)
        #expect(komga.written.last?.1.position == .page(55, from: 200))
        #expect(service.shelf.readingState(volume.identifier)?.position == .page(55, from: 200))
    }

    @Test("Stale protection: if the server meanwhile has a newer, different state, the pending one drops")
    func stale() async throws {
        let (service, komga, volume) = await service()
        komga.set(network: .unreachable)
        try await service.write(state(40, before: 600), for: volume.identifier)
        komga.set(network: .reachable)
        try await komga.write(state(120), for: volume.identifier)  // the iPad was faster
        let previously = komga.written.count
        await service.supply()
        #expect(service.pending == 0)
        #expect(komga.written.count == previously)
        #expect(service.shelf.readingState(volume.identifier)?.position == .page(120, from: 200))
    }

    @Test("A definitive refusal rolls the state back and throws; the queue stays empty")
    func final() async throws {
        let (service, _, volume) = await service()
        let fremd = TitleID(source: volume.identifier.source, id: "gibt-es-nicht")
        await #expect(throws: SourceError.self) {
            try await service.write(state(3), for: fremd)
        }
        #expect(service.pending == 0)
    }

    @Test(
        "Deciding: never started → begin; server further and newer → question; here further → silently send")
    func decide() async throws {
        let (service, komga, volume) = await service()
        #expect(await service.decide(for: volume.identifier) == .begin)

        // Read elsewhere: server carries 126, nothing here → adopted without a question.
        try await komga.write(state(126), for: volume.identifier)
        let first = await service.decide(for: volume.identifier)
        #expect(first == .take(state(126).withTime(first.state!.timestamp), supply: false))
        #expect(service.shelf.readingState(volume.identifier)?.position == .page(126, from: 200))

        // Continued reading here (without network), then network: resubmit silently.
        komga.set(network: .unreachable)
        try await service.write(state(140), for: volume.identifier)
        komga.set(network: .reachable)
        let second = await service.decide(for: volume.identifier)
        #expect(second.state?.position == .page(140, from: 200))
        if case .question = second { Issue.record("no question expected") }

        // The iPad reads on (newer, further): the question.
        await service.supply()
        try await komga.write(state(180), for: volume.identifier)
        let third = await service.decide(for: volume.identifier)
        guard case .question(let here, let there) = third else {
            Issue.record("question expected, was \(third)")
            return
        }
        #expect(here.position == .page(140, from: 200))
        #expect(there.position == .page(180, from: 200))

        // "Stay here" writes the local state to the server.
        await service.retain(at: here, for: volume.identifier)
        #expect(komga.written.last?.1.position == .page(140, from: 200))
        // "Continue there" adopts.
        service.adopt(there, for: volume.identifier)
        #expect(service.shelf.readingState(volume.identifier)?.position == .page(180, from: 200))
    }

    @Test("Without network the local state decides — without a question")
    func offlineDecide() async throws {
        let (service, komga, volume) = await service()
        try await service.write(state(9), for: volume.identifier)
        komga.set(network: .unreachable)
        let e = await service.decide(for: volume.identifier)
        #expect(e.state?.position == .page(9, from: 200))
        if case .question = e { Issue.record("no question expected") }
    }
}

extension ReadingState {
    fileprivate func withTime(_ time: Date) -> ReadingState {
        ReadingState(position: position, timestamp: time, device: device, completed: completed)
    }
}
