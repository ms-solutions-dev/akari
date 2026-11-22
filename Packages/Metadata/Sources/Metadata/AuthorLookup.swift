import Bedrock
import CryptoKit
import Foundation
import SourcesKit

/// Fetches an ``AuthorProfile`` from Wikipedia and Wikidata: four small requests,
/// cached for a week, never without a network.
///
/// **Why an outside source:** Grimmory, Komga and Audiobookshelf only know authors as
/// names on books. Pictures and life dates exist only there. That is why the lookup
/// runs **only when switched on** (`autoren.wikipedia`, off by default): otherwise the
/// author's name never leaves the home network.
///
/// **The route:** `{language}.wikipedia.org/api/rest_v1/page/summary/{name}` (follows
/// redirects, so "M. L. Brandt" is enough for "Margarete L. Brandt"). If the page is a
/// disambiguation page or missing, the same question goes to the English one. The
/// response names the Wikidata ID; from there three statements via the REST interface
/// (`/entities/items/{Q}/statements?property=`): occupation (P106), birth (P569), death
/// (P570), one at a time because the full record of a well-known person weighs 300 kB.
///
/// **The occupation check:** A hit only counts if Wikidata lists the person as a
/// writer (author, novelist, mangaka, comic artist, journalist, illustrator …) or the
/// short description says so ("Schriftstellerin", "writer"); otherwise a namesake
/// racing driver would get his career on the author page.
public actor AuthorLookup {

    private let transport: any Transport
    private let folder: URL?
    /// The app's language first, then English: authors without a German article
    /// usually have an English one.
    private let languages: [String]
    private let now: @Sendable () -> Date
    private var ongoing: [String: Task<AuthorProfile?, Never>] = [:]

    /// One week: life dates rarely change, and a death date can wait a day.
    public static let shelfLife: TimeInterval = 7 * 86_400
    /// What Wikimedia requires: a descriptive User-Agent with contact details.
    public static let identifier = "Akari/0.1 (https://ms-solutions.dev) reading app"

    /// - Parameters:
    ///   - folder: where the profiles are stored; `nil` turns disk storage off (tests).
    public init(
        transport: any Transport = URLSession.shared, folder: URL?,
        language: String = AuthorLookup.appLanguage,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.folder = folder
        self.languages = language == "en" ? ["en"] : [language, "en"]
        self.now = now
    }

    /// The app's UI language as a Wikipedia code.
    public static var appLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return ["de", "en", "tr"].contains(code) ? code : "en"
    }

    /// The profile for a name: from the cache, otherwise fetched; `nil` if Wikipedia
    /// knows nobody by that name who writes. A second caller joins the request in
    /// flight.
    public func profile(_ name: String) async -> AuthorProfile? {
        let lookupKey = AuthorName.lookupKey(name)
        guard !lookupKey.isEmpty else { return nil }
        if let entry = read(lookupKey), now().timeIntervalSince(entry.fetched) < Self.shelfLife {
            return entry.profile
        }
        if let task = ongoing[lookupKey] { return await task.value }
        let task = Task<AuthorProfile?, Never> { [self] in
            let profile = await self.fetch(AuthorName.display(name))
            self.write(Item(profile: profile, fetched: self.now()), for: lookupKey)
            return profile
        }
        ongoing[lookupKey] = task
        let result = await task.value
        ongoing[lookupKey] = nil
        return result
    }

    /// Whether a profile is already cached, so the page can show its header without waiting.
    public func present(_ name: String) -> AuthorProfile? {
        read(AuthorName.lookupKey(name))?.profile
    }

    // MARK: - Fetching

    func fetch(_ name: String) async -> AuthorProfile? {
        for language in languages {
            guard let page = await summary(name, language: language) else { continue }
            let facts = await wikidataFacts(page.wikibaseItem)
            guard Self.writes(occupations: facts.occupations, short: page.description) else { return nil }
            return AuthorProfile(
                name: page.title, short: page.description, text: Self.cleaned(page.extract),
                image: page.thumbnail.flatMap { Self.withoutQuery($0.source) },
                born: facts.born, died: facts.died,
                article: page.contentUrls?.mobile?.page ?? page.contentUrls?.desktop?.page,
                language: language, fetched: now())
        }
        return nil
    }

    struct Summary: Decodable {
        enum CodingKeys: String, CodingKey {
            case type, title, description, extract, thumbnail
            case wikibaseItem = "wikibase_item"
            case contentUrls = "content_urls"
        }
        let type: String
        let title: String
        let description: String?
        let extract: String?
        let thumbnail: Thumbnail?
        let wikibaseItem: String?
        let contentUrls: Addresses?

        struct Thumbnail: Decodable {
            let source: URL
        }
        struct Addresses: Decodable {
            let desktop: Page?
            let mobile: Page?
            struct Page: Decodable {
                let page: URL
            }
        }
    }

    func summary(_ name: String, language: String) async -> Summary? {
        let title = name.replacingOccurrences(of: " ", with: "_")
        guard
            let path = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let address = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(path)"),
            let data = await load(address),
            let response = try? JSONDecoder().decode(Summary.self, from: data),
            response.type == "standard"
        else { return nil }
        return response
    }

    struct Facts {
        var occupations: [String] = []
        var born: LifeDate?
        var died: LifeDate?
    }

    /// One after the other, not in parallel: the three questions go to the same path and
    /// differ only in the query, so sequential keeps the order occupation, birth, death
    /// fixed in a recording too. Occupation first: if the person is not a writer, that
    /// saves two requests.
    func wikidataFacts(_ q: String?) async -> Facts {
        var facts = Facts()
        guard let q, q.hasPrefix("Q") else { return facts }
        facts.occupations = await statements(q, "P106").compactMap { $0.item }
        let anyWriting = facts.occupations.contains { Self.writingOccupations.contains($0) }
        guard facts.occupations.isEmpty || anyWriting else { return facts }
        facts.born = await statements(q, "P569").lazy.compactMap { $0.time }.first
        facts.died = await statements(q, "P570").lazy.compactMap { $0.time }.first
        return facts
    }

    /// A statement from the Wikidata REST interface. The content is written differently
    /// per data type: a string for items (`"Q36180"`), a dictionary for times, hence
    /// the custom decoder.
    struct Statement: Decodable {
        let rank: String?
        let value: Value?

        struct Value: Decodable {
            let type: String
            let content: Content?
        }

        enum Content: Decodable {
            case item(String)
            case time(String, Int)

            struct Moment: Decodable {
                let time: String
                let precision: Int
            }

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let text = try? single.decode(String.self) {
                    self = .item(text)
                } else {
                    let time = try single.decode(Moment.self)
                    self = .time(time.time, time.precision)
                }
            }
        }

        var item: String? {
            guard rank != "deprecated", case .item(let id)? = value?.content else { return nil }
            return id
        }

        var time: LifeDate? {
            guard rank != "deprecated", case .time(let time, let accuracy)? = value?.content else {
                return nil
            }
            return LifeDate(time: time, accuracy: accuracy)
        }
    }

    func statements(_ q: String, _ property: String) async -> [Statement] {
        guard
            let address = URL(
                string: "https://www.wikidata.org/w/rest.php/wikibase/v1/entities/items/\(q)/statements"
            )?.appending(queryItems: [URLQueryItem(name: "property", value: property)]),
            let data = await load(address),
            let response = try? JSONDecoder().decode([String: [Statement]].self, from: data)
        else { return [] }
        return response[property] ?? []
    }

    func load(_ address: URL) async -> Data? {
        var request = URLRequest(url: address)
        request.setValue(Self.identifier, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        guard let (data, response) = try? await transport.send(request), response.statusCode == 200 else {
            return nil
        }
        return data
    }

    // MARK: - Rules

    /// Wikidata occupations that write: writer Q36180, novelist Q6625963, author Q482980,
    /// children's author Q4853732, poet Q49757, playwright Q214917, screenwriter Q28389,
    /// non-fiction writer Q15980158, essayist Q11774202, science fiction writer Q18844224,
    /// fantasy writer Q3658608, mangaka Q191633, comics artist Q715301, comics writer
    /// Q10297252, cartoonist Q1114448, illustrator Q644687, journalist Q1930187,
    /// philosopher Q4964182, historian Q201788, translator Q333634, biographer Q1371378,
    /// crime writer Q10800557, young-adult author Q12144794.
    static let writingOccupations: Set<String> = [
        "Q36180", "Q6625963", "Q482980", "Q4853732", "Q49757", "Q214917", "Q28389", "Q15980158",
        "Q11774202", "Q18844224", "Q3658608", "Q191633", "Q715301", "Q10297252", "Q1114448", "Q644687",
        "Q1930187", "Q4964182", "Q201788", "Q333634", "Q1371378", "Q10800557", "Q12144794",
    ]

    /// Words in the short description that say the same, for entries without an occupation.
    static let writingWords = [
        "schriftsteller", "autor", "romancier", "dichter", "mangaka", "comiczeichner", "comicautor",
        "illustrator", "journalist", "drehbuch", "writer", "author", "novelist", "poet", "cartoonist",
        "comics", "manga", "screenwriter", "yazar", "romancı", "şair", "çizer",
    ]

    /// Occupation **or** short description: Wikidata lists Reklind Glozo as a director, the
    /// short description says "Regisseurin und Autorin", so she writes.
    static func writes(occupations: [String], short: String?) -> Bool {
        if occupations.contains(where: { writingOccupations.contains($0) }) { return true }
        guard let short = short?.lowercased() else { return false }
        return writingWords.contains { short.contains($0) }
    }

    /// The paragraph without the square brackets of the phonetic transcription:
    /// "Margarete L. Brandt [ˈmarɡaˌreːtə …], ist …" reads better without.
    static func cleaned(_ text: String?) -> String? {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        while let on = t.firstIndex(of: "["), let to = t[on...].firstIndex(of: "]") {
            t.removeSubrange(on...to)
        }
        t = t.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " ,", with: ",")
        return t.isEmpty ? nil : t
    }

    /// Wikipedia's thumbnail without the query (`utm_source=…`). It arrives at 330 px,
    /// enough for the 88 pt circle on a 3x screen; `600px-` in the same place gets a 400
    /// from Commons when the original is smaller.
    static func withoutQuery(_ address: URL) -> URL? {
        var share = URLComponents(url: address, resolvingAgainstBaseURL: false)
        share?.query = nil
        return share?.url
    }

    // MARK: - Storage

    struct Item: Codable {
        let profile: AuthorProfile?
        let fetched: Date

        enum CodingKeys: String, CodingKey, CaseIterable {
            case profile = "profil"
            case fetched = "geholt"
        }
    }

    private func file(_ lookupKey: String) -> URL? {
        guard let folder else { return nil }
        let hash = SHA256.hash(data: Data(lookupKey.utf8)).prefix(12).map { String(format: "%02x", $0) }
            .joined()
        return folder.appending(path: hash + ".json")
    }

    private func read(_ lookupKey: String) -> Item? {
        guard let file = file(lookupKey), let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Item.self, from: data)
    }

    private func write(_ entry: Item, for lookupKey: String) {
        guard let folder, let file = file(lookupKey) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
