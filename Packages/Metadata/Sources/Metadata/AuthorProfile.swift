import Foundation

/// What Wikipedia and Wikidata say about an author, as far as the author page shows
/// it: picture, life dates, a sentence, a paragraph, the link to the article.
///
/// Where something is missing it is `nil` and the page leaves the row out, as with
/// ``SourcesKit/Title``. The profile is cached as JSON (see ``AuthorLookup``), hence
/// `Codable`.
public struct AuthorProfile: Sendable, Codable, Hashable {
    /// The name as the article is titled: "Margarete L. Brandt" for "M. L. Brandt".
    public let name: String
    /// The short description from Wikidata, e.g. "schwedische Lyrikerin, Autorin der Nebelinsel-Gedichte".
    public let short: String?
    /// The article's first paragraph, without phonetic-transcription brackets.
    public let text: String?
    /// The thumbnail, 330 pixels wide.
    public let image: URL?
    public let born: LifeDate?
    public let died: LifeDate?
    /// The article ("Read on Wikipedia").
    public let article: URL?
    /// `de`, `en`: which Wikipedia answered.
    public let language: String
    public let fetched: Date

    public init(
        name: String, short: String? = nil, text: String? = nil, image: URL? = nil, born: LifeDate? = nil,
        died: LifeDate? = nil, article: URL? = nil, language: String, fetched: Date = Date()
    ) {
        self.name = name
        self.short = short
        self.text = text
        self.image = image
        self.born = born
        self.died = died
        self.article = article
        self.language = language
        self.fetched = fetched
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case short = "kurz"
        case text
        case image = "bild"
        case born = "geboren"
        case died = "gestorben"
        case article = "artikel"
        case language = "sprache"
        case fetched = "geholt"
    }
}

/// A date as precise as Wikidata knows it: day (`precision` 11), month (10) or just
/// the year (9), e.g. "14 March 1958", "March 1958", "1958". Years BC are left out;
/// authors on the shelf are younger.
public struct LifeDate: Sendable, Codable, Hashable {
    public let year: Int
    public let month: Int?
    public let day: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// From Wikidata's time value: `+1958-03-14T00:00:00Z` with `precision`.
    public init?(time: String, accuracy: Int) {
        guard time.hasPrefix("+") else { return nil }
        let share = time.dropFirst().prefix(10).split(separator: "-").compactMap { Int($0) }
        guard share.count == 3, share[0] > 0 else { return nil }
        year = share[0]
        month = accuracy >= 10 && share[1] > 0 ? share[1] : nil
        day = accuracy >= 11 && share[2] > 0 ? share[2] : nil
    }

    /// For display, in the device's language: day, month and year as far as known.
    public func text(_ locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month ?? 1, day: day ?? 1))
        else { return String(year) }
        var format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).year()
        if month != nil { format = format.month(.wide) }
        if day != nil { format = format.day() }
        return date.formatted(format)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case year = "jahr"
        case month = "monat"
        case day = "tag"
    }
}
