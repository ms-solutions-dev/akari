import Foundation
import SourcesKit
import Testing

@testable import ReadingProgress

@Suite("ConflictRule")
struct ConflictRuleTests {

    private func state(_ page: Int, before seconds: TimeInterval = 0, done: Bool = false) -> ReadingState {
        ReadingState(
            position: .page(page, from: 200), timestamp: Date(timeIntervalSince1970: 1_000_000 - seconds),
            completed: done)
    }

    @Test("Nothing here, nothing there: from the start")
    func begin() {
        #expect(ConflictRule.decide(local: nil, server: nil) == .begin)
    }

    @Test("Only here: supply. Only there: take, no questions asked")
    func oneSided() {
        let s = state(40)
        #expect(ConflictRule.decide(local: s, server: nil) == .take(s, supply: true))
        #expect(ConflictRule.decide(local: nil, server: s) == .take(s, supply: false))
    }

    @Test("Without a server what is here counts, and is supplied later")
    func offline() {
        let s = state(40)
        #expect(
            ConflictRule.decide(local: s, server: nil, reachable: false) == .take(s, supply: true)
        )
        #expect(ConflictRule.decide(local: nil, server: nil, reachable: false) == .begin)
    }

    @Test("Same state within the tolerance: the server, nothing to supply")
    func equal() {
        let here = state(40)
        let there = state(41, before: 100)
        #expect(ConflictRule.decide(local: here, server: there) == .take(there, supply: false))
    }

    @Test("Read further here, server carries our own old state: forward silently")
    func forwardSilently() {
        let own = state(40, before: 600)
        let here = state(80)
        #expect(
            ConflictRule.decide(local: here, server: own, own: own)
                == .take(here, supply: true))
        // Even without a track: here is newer.
        #expect(ConflictRule.decide(local: here, server: own) == .take(here, supply: true))
    }

    @Test("Read further elsewhere (server newer and further): the conflict sheet")
    func question() {
        let here = state(40, before: 600)
        let there = state(126)
        #expect(ConflictRule.decide(local: here, server: there) == .question(here: here, there: there))
        // Finished there: also worth a question.
        let done = state(200, done: true)
        #expect(
            ConflictRule.decide(local: state(199, before: 600), server: done)
                == .question(here: state(199, before: 600), there: done))
    }

    @Test("Reset elsewhere (server newer, but behind): the server, silently")
    func resetElsewhere() {
        let here = state(120, before: 600)
        let there = state(1)
        #expect(ConflictRule.decide(local: here, server: there) == .take(there, supply: false))
    }

    @Test("The state behind the decision")
    func state() {
        let s = state(3)
        #expect(Resolution.begin.state == nil)
        #expect(Resolution.take(s, supply: false).state == s)
        #expect(Resolution.question(here: s, there: state(9)).state == s)
    }
}

@Suite("Queue")
struct QueueTests {

    private let identifier = TitleID(
        source: SourceID(provider: .komga, server: "comics.example"), id: "b1")

    @Test("One entry per title, the last wins; forgetting is an entry without a state")
    func spots() {
        let w = Queue(folder: nil)
        #expect(w.empty)
        w.spot(ReadingState(position: .page(3, from: 9), timestamp: Date()), for: identifier)
        w.spot(ReadingState(position: .page(5, from: 9), timestamp: Date()), for: identifier)
        #expect(w.all.count == 1)
        #expect(w.pending(identifier)?.state?.position == .page(5, from: 9))
        w.spot(nil, for: identifier)
        #expect(w.pending(identifier)?.state == nil)
        #expect(w.all.count == 1)
        w.remove(identifier)
        #expect(w.empty)
    }

    @Test("Queue and track survive a restart")
    func disk() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "fortschritt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = ReadingState(
            position: .page(7, from: 9), timestamp: Date(timeIntervalSince1970: 5), device: "iPad")
        do {
            let w = Queue(folder: folder)
            w.spot(state, for: identifier)
            w.save(own: state, for: identifier)
        }
        let new = Queue(folder: folder)
        #expect(new.pending(identifier)?.state == state)
        #expect(new.own(identifier) == state)
    }
}
