import Foundation
import Testing

@testable import Bedrock

/// **The identifier is read aloud, not skimmed.**
///
/// Between the viewer in the living room and support there is a phone call.
/// Everything checked here decides whether the string survives that path.
@Suite("Diagnostics identifier")
struct DiagnosticsIDTests {

    /// **Confusable characters are out.** A "zero or O?" on the phone costs more
    /// than the four characters the alphabet loses.
    @Test("The alphabet contains no confusable character")
    func alphabetHasNoConfusables() {
        let forbidden: Set<Character> = ["0", "O", "1", "I", "L", "8", "B", "5", "S", "2", "Z"]
        let used = Set(DiagnosticsID.alphabet)

        #expect(used.isDisjoint(with: forbidden))
        // And enough must remain to tell them apart: 24 characters at six positions
        // are around 191 million possibilities.
        #expect(DiagnosticsID.alphabet.count >= 20)
        #expect(Set(DiagnosticsID.alphabet).count == DiagnosticsID.alphabet.count)
    }

    @Test("The identifier has the form XXXX-XX")
    func shapeIsFourTwo() {
        let identifier = DiagnosticsID.new()

        #expect(identifier.count == DiagnosticsID.spots + 1)
        #expect(Array(identifier)[4] == "-")
        #expect(
            identifier.filter { $0 != "-" }.allSatisfy(DiagnosticsID.alphabet.contains),
            "\(identifier) trägt ein Zeichen außerhalb des Alphabets")
    }

    /// **A new one per submission.** Two reports from the same device are two cases;
    /// an identifier valid for both helps nobody find the second.
    @Test("Two identifiers are almost never the same")
    func twoAreVirtuallyNeverEqual() {
        let many = Set((0..<500).map { _ in DiagnosticsID.new() })
        // With 191 million possibilities and 500 draws the probability of a duplicate
        // is 0.065 percent. So what is demanded is not "all different" but "almost
        // all"; otherwise the test would fail one day without anything being broken.
        #expect(many.count >= 495)
    }

    // MARK: - In the report

    /// **A line of its own with a fixed prefix:** whoever searches a folder full of
    /// reports does so with a tool that finds lines.
    @Test("The identifier appears as a line of its own and is found again")
    func lineIsFoundAgain() {
        let identifier = DiagnosticsID.new()
        let report = """
            CineLounge — Diagnose
            Erstellt: irgendwann
            \(DiagnosticsID.headerLine(identifier))
            Version: 1.0

            ═══ Fehler ═══
            nichts
            """

        #expect(DiagnosticsID.fromReport(report) == identifier)
    }

    @Test("Without an identifier the report reports none")
    func withoutIDNoneIsReported() {
        #expect(DiagnosticsID.fromReport("CineLounge — Diagnose\nVersion: 1.0") == nil)
        // Even an empty line behind the prefix is no identifier.
        #expect(DiagnosticsID.fromReport("Diagnose-Kennung:   ") == nil)
    }

    /// The hyphen sits after four characters, tested with an identifier of known
    /// characters so the test does not roll dice.
    @Test("The hyphen sits after four characters")
    func hyphenSitsAfterFour() {
        #expect(DiagnosticsID.hyphenate("ACDEFG") == "ACDE-FG")
        // Whatever does not have the right length is left untouched; an invented
        // separation would be worse than none.
        #expect(DiagnosticsID.hyphenate("ACD") == "ACD")
    }
}
