import Foundation
import SourcesKit

/// The extensions the source carries as titles — and what they are.
public enum FileType: String, Sendable, CaseIterable {
    case epub, pdf, cbz, cbr

    public var kind: Kind { self == .cbz || self == .cbr ? .manga : .book }

    public init?(name: String) {
        self.init(rawValue: (name as NSString).pathExtension.lowercased())
    }
}

/// What a path says about a file before anybody opens it: name, author, series and volume from
/// folder names and file names.
///
/// **Three schemes, in this order:** Calibre (`Author/Title/Title - Author.epub`, the title
/// folder may carry `(123)` or `(Series #1)` — the folder is the title), `Author - Title.epub`
/// (a folder full of files — whoever equals a folder is the author, otherwise the first part;
/// the rest "Holmes 03 - Exit" stays together for the series), otherwise the file name. A parent
/// folder that looks like a person's name ("Jules Verne", "Verne, Jules") is the author;
/// "Fantasy" is not. For manga the parent folder is the series and the first number in the name
/// is the volume.
///
/// **The file name beats the folder for the author:** In `Jules Verne/Hector Servadac (Voyages
/// extraordinaires #1)/Hector Servadac - Michel Verne.epub` Michel Verne is the author. Calibre
/// writes the book's authors into the file name and only the sort name of the first one into the
/// folder — the folder is the shelf board, the file name the book. The folder counts only if the
/// file name names no author.
///
/// This is a start, not a verdict: the backfill from the OPF replaces what was guessed here as
/// soon as it is through.
public enum PathMetadata {

    public struct Finding: Sendable, Hashable {
        public var name: String
        public var authors: [String] = []
        public var bookSeries: String?
        public var volume: Double?
    }

    /// - Parameter path: the path relative to the account's folder, `Jules Verne/Dracula/Dracula - Bram Stoker.epub`.
    public static func extract(_ path: String, type: FileType) -> Finding {
        let share = path.split(separator: "/").map(String.init)
        let file = share.last ?? path
        let filename = (file as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        let folder = share.dropLast().map { withoutCalibreNumber($0) }
        let parent = folder.last
        let grandparent = folder.count >= 2 ? folder[folder.count - 2] : nil

        if type.kind == .manga {
            return manga(filename, parent: parent)
        }

        var finding = Finding(name: filename)
        let halves = filename.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }

        let parentTitle = parent.map { bookSeries(from: $0)?.0 ?? $0 }
        if let parent, let parentTitle,
            equal(parentTitle, filename) || halves.contains(where: { equal(parentTitle, $0) })
        {
            finding.name = parent
            if halves.count >= 2, let other = halves.first(where: { !equal(parentTitle, $0) }) {
                finding.authors = authors(other)
            } else if let grandparent, looksLikeAuthor(grandparent) {
                finding.authors = authors(grandparent)
            }
        } else if halves.count >= 2 {
            if let parent, halves.contains(where: { equal(parent, $0) }) {
                finding.authors = authors(parent)
                finding.name = halves.filter { !equal(parent, $0) }.joined(separator: " - ")
            } else if let grandparent, halves.contains(where: { equal(grandparent, $0) }) {
                finding.authors = authors(grandparent)
                finding.name = halves.filter { !equal(grandparent, $0) }.joined(separator: " - ")
            } else {
                finding.authors = authors(halves[0])
                finding.name = halves.dropFirst().joined(separator: " - ")
            }
        } else if let parent, looksLikeAuthor(parent) {
            finding.authors = authors(parent)
        }

        if let (name, bookSeries, volume) = bookSeries(from: finding.name) {
            finding.name = name
            finding.bookSeries = bookSeries
            finding.volume = volume
        }
        return finding
    }

    /// Manga: the folder is the series if the file name carries it ("Blawosfil Saga/Blawosfil
    /// Saga 001.cbz") or is just a number ("Blawosfil Saga/001.cbz"); the first number after the series
    /// name is the volume. Otherwise the name says what it can — a folder "Comics" is no series.
    static func manga(_ filename: String, parent: String?) -> Finding {
        var finding = Finding(name: filename)
        let numberOnly =
            hit(
                #"^(?:c|ch\.?|v|vol\.?|kap\.?|kapitel|band|bd\.?|#)?[\s._-]*(\d{1,4}(?:[.,]\d+)?)$"#,
                in: filename)
            != nil
        if let parent, numberOnly || filename.range(of: parent, options: .caseInsensitive) != nil {
            finding.bookSeries = parent
            var remainder = filename
            if let area = remainder.range(of: parent, options: .caseInsensitive) {
                remainder.removeSubrange(area)
            }
            finding.volume = firstNumber(remainder)
        } else if let (name, bookSeries, volume) = bookSeries(from: filename) {
            finding.name = name
            finding.bookSeries = bookSeries
            finding.volume = volume
        } else if let hit = hit(
            #"^(.+?)[\s_]+(?:c|ch\.?|v|vol\.?|#|band|bd\.?)?\s*(\d{1,4}(?:[.,]\d+)?)$"#, in: filename)
        {
            finding.bookSeries = hit[0]
            finding.volume = integer(hit[1])
        }
        return finding
    }

    /// "Title (Series #3)", "Title (Series 3)", "Series 03 - Title", "Series - Band 3 - Title",
    /// "Series #3 - Title" → title, series, volume.
    static func bookSeries(from name: String) -> (String, String, Double)? {
        if let t = hit(#"^(.+?)\s*\((.+?)\s+#?(\d+(?:[.,]\d+)?)\)$"#, in: name) {
            return (t[0], t[1], integer(t[2]) ?? 0)
        }
        if let t = hit(
            #"^(.+?)\s*(?:-\s*)?(?:#|band|bd\.?|vol\.?|volume|teil|tome)\s*(\d+(?:[.,]\d+)?)\s*-\s*(.+)$"#,
            in: name)
        {
            return (t[2], t[0], integer(t[1]) ?? 0)
        }
        if let t = hit(#"^(.+?)\s+(\d{1,3})\s*-\s*(.+)$"#, in: name) {
            return (t[2], t[0], integer(t[1]) ?? 0)
        }
        return nil
    }

    /// Calibre appends the book ID to the title folder: `Miakus (123)`.
    static func withoutCalibreNumber(_ folder: String) -> String {
        folder.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
    }

    /// "Verne, Jules" → "Jules Verne"; "Jules Verne & Michel Verne" → two.
    static func authors(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "&;")).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .map { name in
            let share = name.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return share.count == 2 && !share[1].isEmpty ? share[1] + " " + share[0] : name
        }
    }

    /// Two to four words, each capitalized, no digits — or "Surname, First name".
    static func looksLikeAuthor(_ text: String) -> Bool {
        if text.contains(","), text.components(separatedBy: ",").count == 2 { return true }
        let words = text.split(separator: " ")
        guard (2...4).contains(words.count) else { return false }
        return words.allSatisfy { w in
            guard let first = w.first else { return false }
            return first.isUppercase && !w.contains(where: \.isNumber)
        }
    }

    static func equal(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func firstNumber(_ text: String) -> Double? {
        hit(#"(\d{1,4}(?:[.,]\d+)?)"#, in: text).flatMap { integer($0[0]) }
    }

    static func integer(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// The groups of the first match, in order; `nil` without a match.
    static func hit(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
                ?? ""
        }
    }
}
