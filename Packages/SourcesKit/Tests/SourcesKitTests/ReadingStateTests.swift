import Foundation
import Testing

@testable import SourcesKit

@Suite("Reading state")
struct ReadingStateTests {
    let now = Date(timeIntervalSince1970: 1_789_581_600)

    @Test("The fraction comes from the position — page, CFI, second")
    func fraction() {
        #expect(ReadingState(position: .page(63, from: 205), timestamp: now).fraction == 63.0 / 205.0)
        #expect(
            ReadingState(position: .position(cfi: "epubcfi(/6/12!/4/2)", fraction: 0.016), timestamp: now)
                .fraction == 0.016)
        #expect(
            ReadingState(position: .second(176, from: 38_000), timestamp: now).fraction == 176.0 / 38_000.0)
    }

    @Test("Nonsensical values are capped to 0…1, division by zero gives 0")
    func cap() {
        #expect(ReadingState(position: .page(300, from: 205), timestamp: now).fraction == 1)
        #expect(ReadingState(position: .page(3, from: 0), timestamp: now).fraction == 0)
        #expect(ReadingState(position: .position(cfi: "x", fraction: 1.7), timestamp: now).fraction == 1)
        #expect(ReadingState(position: .position(cfi: "x", fraction: -0.2), timestamp: now).fraction == 0)
        #expect(ReadingState(position: .second(-5, from: 100), timestamp: now).fraction == 0)
        #expect(ReadingState(position: .fraction(3), timestamp: now).fraction == 1)
    }

    @Test("Started means: above zero and not completed")
    func started() {
        #expect(ReadingState(position: .page(63, from: 205), timestamp: now).started)
        #expect(!ReadingState(position: .page(0, from: 205), timestamp: now).started)
        #expect(
            !ReadingState(position: .page(205, from: 205), timestamp: now, completed: true).started)
    }

    @Test("Completed is what the server says — even at 99.4 %")
    func completedByServer() {
        let audiobook = ReadingState(
            position: .second(37_780, from: 38_000), timestamp: now, completed: true)
        #expect(audiobook.fraction < 1)
        #expect(audiobook.completed)
        #expect(!audiobook.started)
        let lastPage = ReadingState(position: .page(205, from: 205), timestamp: now)
        #expect(lastPage.fraction == 1)
        #expect(!lastPage.completed)
    }

    @Test("A reading state survives the trip through JSON with all three positions")
    func codable() throws {
        let states = [
            ReadingState(position: .page(63, from: 205), timestamp: now, device: "iPhone"),
            ReadingState(position: .position(cfi: "epubcfi(/6/12!/4/2)", fraction: 0.016), timestamp: now),
            ReadingState(position: .second(176, from: 38_000), timestamp: now, completed: true),
        ]
        let data = try JSONEncoder().encode(states)
        #expect(try JSONDecoder().decode([ReadingState].self, from: data) == states)
    }
}
