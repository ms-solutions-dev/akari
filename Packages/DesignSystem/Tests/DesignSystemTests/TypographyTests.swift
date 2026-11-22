import Foundation
import Testing

@testable import DesignSystem

@Suite("Typography")
struct TypographyTests {

    @Test("Newsreader lies in the package and can be registered")
    func newsreader() {
        #expect(
            Bundle.module.url(forResource: "Newsreader", withExtension: "ttf", subdirectory: "Schriften")
                != nil)
        #expect(Typography.serifAvailable)
    }

    @Test("The license travels along")
    func license() throws {
        let url = try #require(
            Bundle.module.url(forResource: "OFL", withExtension: "txt", subdirectory: "Schriften"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("SIL Open Font License"))
    }

    @Test("Base sizes follow the order of the text styles")
    func sizes() {
        #expect(Typography.size(.largeTitle) > Typography.size(.title))
        #expect(Typography.size(.title) > Typography.size(.body))
        #expect(Typography.size(.body) > Typography.size(.caption2))
    }
}
