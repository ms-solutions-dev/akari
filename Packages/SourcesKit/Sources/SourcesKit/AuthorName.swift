import Foundation

/// An author name as three servers write it — and as the app means it.
///
/// Grimmory writes "Brandt, M. L.", Komga's komf "M. L. Brandt", Audiobookshelf
/// "M.L. Brandt": three spellings, one person. ``lookupKey(_:)`` turns them into
/// a comparison value (last-name-first flipped, dots and spaces normalised,
/// lower case), ``display(_:)`` the form for the eye ("M. L. Brandt") — the
/// author page, the authors view and the Wikipedia lookup all compute with
/// the same key.
public enum AuthorName {

    /// "Brandt, M. L." → "M. L. Brandt"; "M.L. Brandt" → "M. L. Brandt"; otherwise
    /// only whitespace normalised.
    public static func display(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Last name, first name — exactly one comma, both sides non-empty.
        let share = name.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if share.count == 2, !share[0].isEmpty, !share[1].isEmpty {
            name = share[1] + " " + share[0]
        }
        // "M.L." → "M. L.": a space after every dot that is followed by a letter.
        var result = ""
        var previously: Character?
        for character in name {
            if let v = previously, v == ".", character.isLetter { result.append(" ") }
            result.append(character)
            previously = character
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The comparison value — ``display(_:)`` in lower case, without diacritics,
    /// without dots.
    public static func lookupKey(_ raw: String) -> String {
        display(raw)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The initials for the image-less image — "MLB" for "M. L. Brandt", at most three.
    public static func initials(_ raw: String) -> String {
        let words = display(raw).split(separator: " ")
        let letters = words.compactMap { $0.first(where: \.isLetter) }
        let chosen = letters.count > 3 ? [letters[0], letters[letters.count - 1]] : letters
        return String(chosen).uppercased()
    }
}
