import Foundation

/// A short identifier for a submitted diagnostics report.
///
/// **What for:** today, submitting reports back the **file name** the server
/// assigned. That answers the question "is it there?" but not the one that
/// matters: the viewer sits in the living room, support has a folder full of
/// reports, and a phone call lies between the two. What has to get through there
/// is short, unambiguous and **readable aloud**.
///
/// ## Why this alphabet
///
/// Confusable characters are out: **0 and O**, **1, I and L**, **8 and B**,
/// **5 and S**, **2 and Z**. Whoever reads an identifier out on the phone reads
/// it once, and a "zero or O?" costs more than the four characters the alphabet
/// loses. That leaves **24** characters; at six positions that is around
/// **191 million** possibilities. This is not a security question but a
/// distinguishing question: two reports from the same viewer must not carry the
/// same identifier.
///
/// ## What it is NOT
///
/// **No secret and no key.** It appears in plain text in the report and on the
/// screen; whoever knows it knows only a string. The report itself stays where
/// it was, on your own server.
///
/// **And not permanent.** A new one per submission: two reports from the same
/// device are two cases, and an identifier valid for both helps nobody find the
/// second.
public enum DiagnosticsID {

    /// The characters an identifier consists of, without anything confusable.
    ///
    /// Read as digits and letters separately it would be shorter; mixed it is
    /// shorter **and** readable aloud, because no character has two names.
    public static let alphabet = Array("34679ACDEFGHJKMNPQRTVWXY")

    /// How many positions the identifier has, without the hyphen.
    public static let spots = 6

    /// Builds a new identifier, `XXXX-XX`.
    ///
    /// **The hyphen sits after four characters**, because a group of six falls apart
    /// when read aloud and two groups of three look like a phone number. Four plus
    /// two reads as a word and a suffix.
    public static func new() -> String {
        hyphenate(String((0..<spots).map { _ in alphabet.randomElement() ?? "X" }))
    }

    /// Inserts the hyphen, separate so tests can build an identifier from known
    /// characters instead of rolling dice.
    static func hyphenate(_ raw: String) -> String {
        let character = Array(raw)
        guard character.count == spots else { return raw }
        return String(character.prefix(4)) + "-" + String(character.suffix(2))
    }

    /// The header line under which the identifier appears in the report.
    ///
    /// **A line of its own, at the very top:** whoever searches a folder full of
    /// reports does so with a tool that finds lines, not with their eyes. The fixed
    /// prefix turns the search into a hit.
    public static let lead = "Diagnose-Kennung: "

    public static func headerLine(_ identifier: String) -> String { lead + identifier }

    /// Reads the identifier back out of a report, for tests and for anyone who
    /// wants to know whether they have the right one in front of them.
    public static func fromReport(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix(lead) {
            let value = line.dropFirst(lead.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
