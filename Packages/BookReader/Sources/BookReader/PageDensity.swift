import Foundation

/// Characters per screen page - the one number from which "Page x of y" is extrapolated for the whole
/// book.
///
/// Density is a property of the **setting** (font, margins, window),
/// not of the page one is currently on. It used to come solely from the
/// visible chapter: a title page with a single word yielded "one
/// character per page", and a long book had 78,000 pages - at the next chapter 600 again.
/// Apple Books sets the whole book in the background for this; Readium cannot, but the
/// principle works: every full chapter the reader traverses yields a sample, and the
/// density is the mean of all samples - stable as long as the setting stays. Short chapters
/// (under two pages or ``minimumCharacters``) yield no sample; the last page
/// of a chapter counts as half full, otherwise every sample would be too small.
///
/// The collection is only cleared when font or window change - then
/// the next chapter measures anew, and until then the old number applies.
struct PageDensity: Sendable {
    static let minimumPages = 2
    static let minimumCharacters = 1_500

    private(set) var samples: [Int: (character: Int, pages: Int)] = [:]

    /// Characters per page over all samples; `nil` as long as no full chapter
    /// has been measured.
    var value: Double? {
        guard !samples.isEmpty else { return nil }
        let character = samples.values.reduce(0) { $0 + $1.character }
        let pages = samples.values.reduce(0.0) { $0 + Double($1.pages) - 0.5 }
        return max(Double(character) / max(pages, 0.5), 1)
    }

    /// Records a measurement - `true` if the chapter qualifies as a sample.
    @discardableResult
    mutating func take(chapter: Int, character: Int, pages: Int) -> Bool {
        guard pages >= PageDensity.minimumPages, character >= PageDensity.minimumCharacters else {
            return false
        }
        samples[chapter] = (character, pages)
        return true
    }

    mutating func clearOut() { samples = [:] }
}
