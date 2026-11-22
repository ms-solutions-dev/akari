import Foundation
import Synchronization

/// Genres as humans read them.
///
/// The servers deliver genres raw: lowercase and English ("drama", "slice of life",
/// "shounen"), the same thing in three spellings ("Sci-Fi", "Science Fiction",
/// "science-fiction"). For readers in the German-speaking countries the library then looked like a
/// database browser, on the iPad over twenty raw entries stood in the sidebar.
///
/// Here every name is folded (lowercase, without accents, separators as spaces) and brought via
/// a table to **one** German name. What the table does not know
/// keeps its name but gets a capital first letter. Because
/// ``Shelf/Genre/lookupKey(for:)`` goes through here, this holds everywhere the same: in the
/// genre row, when filtering and in the sidebar.
public enum GenreNames {

    /// The display name for a raw genre from the server — remembered per spelling. The shell
    /// counts the genres anew on every shelf change, when reading every two seconds; without the
    /// memo that was thousands of `folding(…locale:)` calls on the main thread
    /// for a few dozen distinct words.
    public static func normal(_ raw: String) -> String {
        if let known = saved.withLock({ $0[raw] }) { return known }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: String
        if trimmed.isEmpty {
            result = trimmed
        } else if let german = table[folded(trimmed)] {
            result = german
        } else {
            result = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
        saved.withLock { $0[raw] = result }
        return result
    }

    private static let saved = Mutex<[String: String]>([:])

    /// Lowercase, without accents, hyphen/underscore/slash as space.
    static func folded(_ s: String) -> String {
        let small = s.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de"))
        let separated = small.map { "-_/.".contains($0) ? " " : $0 }
        return String(separated).split(separator: " ").joined(separator: " ")
    }

    /// Folded spelling → German name. German names are included so that
    /// "krimi" and "Krimi" become the same entry.
    static let table: [String: String] = {
        let clusters: [String: [String]] = [
            "Fantasy": ["fantasy", "high fantasy", "epic fantasy"],
            "Science-Fiction": ["science fiction", "sci fi", "scifi", "sf", "science fiction & fantasy"],
            "Krimi": ["krimi", "crime", "crime fiction", "kriminalroman", "detective", "detektiv"],
            "Thriller": ["thriller", "suspense", "psychothriller"],
            "Mystery": ["mystery", "mysteries"],
            "Horror": ["horror", "grusel"],
            "Liebesroman": ["romance", "liebesroman", "liebe", "romantik"],
            "Fantasy-Romance": ["romantasy", "fantasy romance", "paranormal romance"],
            "Erotik": ["erotica", "erotik", "erotic"],
            "Drama": ["drama"],
            "Komödie": ["comedy", "komodie"],
            "Humor": ["humor", "humour", "humorous"],
            "Action": ["action"],
            "Abenteuer": ["adventure", "abenteuer", "action & adventure", "action adventure"],
            "Historischer Roman": [
                "historical", "historical fiction", "historischer roman", "history fiction",
            ],
            "Geschichte": ["history", "geschichte"],
            "Biografie": [
                "biography", "biografie", "biographie", "memoir", "autobiography", "autobiografie",
            ],
            "Sachbuch": ["nonfiction", "non fiction", "sachbuch"],
            "Ratgeber": ["self help", "ratgeber"],
            "Klassiker": ["classics", "classic", "klassiker"],
            "Lyrik": ["poetry", "lyrik", "gedichte"],
            "Kurzgeschichten": ["short stories", "kurzgeschichten", "anthology", "anthologie"],
            "Jugendbuch": ["young adult", "ya", "jugendbuch", "teen"],
            "Kinderbuch": ["children", "childrens", "kinderbuch", "kids"],
            "Gegenwartsliteratur": ["literary fiction", "contemporary", "gegenwartsliteratur"],
            // Calibre and Komga tag almost everything with "Fiction" — that is no genre.
            "Belletristik": ["fiction", "belletristik", "general fiction"],
            "Dystopie": ["dystopia", "dystopian", "dystopie"],
            "Western": ["western"],
            "Übernatürliches": ["supernatural", "paranormal", "ubernaturliches"],
            "Psychologisch": ["psychological"],
            "Alltag": ["slice of life"],
            "Schule": ["school life", "school"],
            "Sport": ["sports", "sport"],
            "Musik": ["music", "musik"],
            "Magie": ["magic", "magie"],
            "Kampfkunst": ["martial arts"],
            "Tragödie": ["tragedy", "tragodie"],
            "Shōnen": ["shounen", "shonen"],
            "Shōjo": ["shoujo", "shojo"],
            "Seinen": ["seinen"],
            "Josei": ["josei"],
            "Isekai": ["isekai"],
            "Mecha": ["mecha"],
            "Ecchi": ["ecchi"],
            "Harem": ["harem"],
            "Boys' Love": ["yaoi", "boys love", "bl", "shounen ai"],
            "Girls' Love": ["yuri", "girls love", "gl", "shoujo ai"],
            "Superhelden": ["superhero", "superheroes", "superhelden"],
            "Krieg": ["war", "military", "krieg"],
            "Reise": ["travel", "reise"],
            "Kochen": ["cooking", "kochen", "food"],
            "Philosophie": ["philosophy", "philosophie"],
            "Religion": ["religion", "spirituality"],
            "Wissenschaft": ["science", "wissenschaft"],
            "Wirtschaft": ["business", "economics", "wirtschaft"],
            "Politik": ["politics", "politik"],
            "Psychologie": ["psychology", "psychologie"],
        ]
        var t: [String: String] = [:]
        for (german, spellings) in clusters {
            for s in spellings { t[folded(s)] = german }
            t[folded(german)] = german
        }
        return t
    }()
}
