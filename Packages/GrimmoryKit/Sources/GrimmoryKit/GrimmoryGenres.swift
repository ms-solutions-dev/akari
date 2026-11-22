import Foundation

/// Maps Grimmory's raw categories to the library's genres. Grimmory takes over the headings
/// of Goodreads and Amazon unfiltered — shelves ("Book Club"), formats ("Audiobook" on 189
/// e-books), settings ("Russia"), publisher numbers ("Klufluve 3926") and headings such as
/// "Dragons & Mythical Creatures Fantasy" sit next to the real genres. The server stays raw;
/// the mapping happens here.
///
/// Counted over a recording of the full list (865 books, 834 with categories, 4,348
/// assignments, **508 distinct categories**). After the mapping **11 genres** remain (six
/// targets were discarded, see below), and no book loses a statement that would be a genre:
///
/// | Target (books)           | The most common raw categories behind it |
/// | --- | --- |
/// | Fantasy (538)            | Fantasy 305, Military Fantasy 166, Fantasy Anthologies 128, Epic Fantasy 98, Paranormal 71, Dragons & Mythical Creatures Fantasy 64, Science Fiction Fantasy 54, Historical Fantasy 52, Magic 50, High Fantasy 50, Supernatural 41 |
/// | Krimi & Thriller (237)   | Thriller 127, Mystery 100, Suspense 63, Crime 49, Mystery Thriller 40, Ghost Thrillers 36, Ghost Mysteries 34, Crime Thrillers 27, Psychic Thrillers 27 — Mystery and Thriller coincide on 87 of 100 books, hence one genre |
/// | Horror (140)             | Horror 108, Ghost Thrillers 36, Ghost Mysteries 34 (both also Krimi & Thriller), Horror Thriller 13 |
/// | Science-Fiction (135)    | Science Fiction 92, Science Fiction Short Stories 35, Humorous Science Fiction 27, Dystopia 21, Post Apocalyptic 13 |
/// | Liebesroman (104)        | Romance 48, Paranormal Vampire Romance 47, Romantic Fantasy 34, Paranormal Romance 23 (the last three also Fantasy) |
/// | Abenteuer (84)           | Adventure 59, Action 13, Action & Adventure Fantasy 9, War 8 |
/// | Kurzgeschichten (68)     | Short Stories 51, Novella 18, Mystery Short Stories 15, Anthologies 7 |
/// | Humor (56)               | Humorous Science Fiction 27, Humor 17, Comedy 10, Humorous Fantasy 9 |
/// | Jugendbuch (54)          | Young Adult 40, Teen 6, Fantasy Romance for Young Adults 6, Young Adult Fantasy 4 |
/// | Historisch (37)          | Historical Fiction 24, Historical 17 |
/// | Roman (26)               | Fiction 255, German Literature 45, Novels 38, Genre Fiction 28, Contemporary 27, Literary Fiction 19 — only if no other genre remains; otherwise every Fantasy volume would also be under "Roman" |
/// | Klassiker (16)           | Classics 14, Fiction Classics 2 |
/// | Manga & Comic (12)       | Manga 5, Graphic Novels 4, Comics & Graphic Novels by Genre 4 |
/// | Sachbuch (9)             | Nonfiction 8, Philosophy 3, Religion 4, Popular Science 2 — weak, see below |
/// | Kinderbuch (8)           | Childrens 5, Middle Grade 2, Kinderbücher 1 |
/// | Biografie (5)            | Biography 4, Memoir 3 — weak |
/// | Lyrik (0)                | Poetry 5, Russian & Soviet Poetry 5 — Amazon attaches them to Stader epics; weak, hence empty today |
/// | Noise (118, dropped)     | Audiobook 189, Adult 78, Ebooks 48, Book Club 31, Urban 27, Erotic Calendars 12, Russia 10, publisher and volume numbers ("Klufluve 3926", "Woromur & Vaibou 03"), prizes ("Silver Lantern Prize 1972"), Kindle-store football on nine Fantasy volumes |
///
/// **Six targets are dropped entirely** (after a review of the recording): all nine "Sachbücher"
/// were noise ("Corporate Culture" on a novel, "Theology" on Groli, "Textbooks" on Priohiblarn,
/// Pandrigrour stories as "Home & Garden"; "Spifliga" carries the headings of a Spaihatdrout Draizugrair book), all
/// twelve "Manga & Comic" too (Miakus prequels as "Manga", Pandrigrour as "Ciswos"), Kinderbuch
/// ("Childrens" on Jis Biplomin) and Biografie likewise; the 104 "Liebesromane" are romantasy
/// (Spocas, Miaceit, Naivik — fantasy with a love story) plus stray "Romance" headings on Pandrigrour,
/// Biskreirau Sleklou, Wanspand Miadrial. Hence ``discarded`` — Sachbuch, Biografie, Kinderbuch, Lyrik, Manga &
/// Comic, Liebesroman never reach the result; the romantasy headings keep contributing Fantasy,
/// the rest is noise. A real romance novel would end up under "Ohne Genre" — the better error
/// for this collection. **11 genres** remain.
///
/// **Unknown stays raw.** Whatever hits neither noise nor table nor keyword stays unchanged
/// in the genre — better a rare genre than a lost one. In the recording nothing is left over.
///
/// The names are German as in the mocks ("Science-Fiction", "Abenteuer") and in the Audible
/// tags of Audiobookshelf ("Fantasy", "Thriller"); Komga (komf) delivers lowercase English
/// ("fantasy", "sci-fi") — a normalization across all sources has yet to catch up.
enum GrimmoryGenres {
    static let fantasy = "Fantasy"
    static let scienceFiction = "Science-Fiction"
    static let crime = "Krimi & Thriller"
    static let horror = "Horror"
    static let romance = "Liebesroman"
    static let historical = "Historisch"
    static let adventure = "Abenteuer"
    static let humor = "Humor"
    static let classics = "Klassiker"
    static let youngAdult = "Jugendbuch"
    static let children = "Kinderbuch"
    static let nonfiction = "Sachbuch"
    static let biography = "Biografie"
    static let novel = "Roman"
    static let comic = "Manga & Comic"
    static let shortStories = "Kurzgeschichten"
    static let poetry = "Lyrik"

    /// All target genres — for tests and counters.
    static let targets: [String] = [
        fantasy, scienceFiction, crime, horror, romance, historical, adventure, humor, classics,
        youngAdult, children, nonfiction, biography, novel, comic, shortStories, poetry,
    ]

    /// Targets that apply only without a narrative genre (reasoning above).
    static let weakTargets: Set<String> = [nonfiction, biography, poetry]

    /// Targets that exist in this collection only as noise (see above) — they stay in the
    /// table so that a hit such as "Romantic Fantasy" still contributes Fantasy, but they drop out
    /// of every result.
    static let discarded: Set<String> = [nonfiction, biography, children, poetry, comic, romance]

    /// What is no genre and therefore dropped: formats, shelves, read status, store headings,
    /// settings, moods. Lowercase, after `normalized`.
    static let noise: Set<String> = [
        "audiobook", "audiobooks", "audible", "ebook", "ebooks", "kindle", "book club", "owned", "to read",
        "to-read", "currently reading", "currently-reading", "read", "favorites", "favourites", "default",
        "next", "lesenswert", "gelesen", "adult", "new adult", "retail", "general", "amazon",
        "foreign language books", "english", "english ebooks", "ebook german", "internet ebook",
        "microsoft word", "audio & mp3 cd", "whispersync for voice", "breilodral-epub", "klenskum", "auf tolino",
        "auf tolino vision 3hd", "auf tolino epos", "drikern-louhem", "clubs & associations",
        "european football championship, fifa world cup & national team",
        "football textbooks & sets of rules", "boys' fashion trainers", "women's jeans",
        "cellular telephones", "cell phones", "general birth", "guide on private speeches",
        "summer jobs & internships", "school, studying & internship in usa", "!usa", "!debütroman", "authors",
        "story", "stories", "katalog", "erotic calendars", "russia", "china", "germany", "france", "england",
        "ireland", "denmark", "hungary", "ukraine", "asia", "africa", "amerika", "großbritannien",
        "the united states of america", "american", "u.s. literature", "20th century", "21st century", "rus",
        "danish", "school", "family", "death", "grief", "revenge", "dark", "abuse", "fostering",
        "children & violence", "gang violence", "murderers", "animals", "womens", "lgbt", "queer", "gay",
        "lesbian", "spicy", "feminism", "social issues", "mental health", "modernism & postmodernism",
        "interpretations of english literature", "celtic, english & welsh", "greek & roman", "victorian",
        "medieval", "urban",
    ]

    /// Amazon appends store suffixes: "Urban Fantasy (Kindle Store)", "Space Opera
    /// (English)", "Hard Science Fiction eBooks", "Science Fiction History &
    /// Criticism" (the novels, not the criticism). The rest is then mapped.
    static let suffixes: [String] = [
        " (kindle store)", " (english)", " (foreign language)", " (dvd & blu-ray)", " ebooks", " ebook",
        " literary criticism", " history & criticism",
    ]

    /// Categories that describe a narrative work without a genre — "Fiction", "Novels",
    /// national literatures. They become `novel` only if nothing else remains.
    static let general: Set<String> = [
        "fiction", "novels", "genre fiction", "literary fiction", "german literature", "contemporary",
        "contemporary fiction", "roman", "romane", "literature", "literature & fiction", "belletristik",
        "deutsche literatur", "gesellschaftsromane", "drama", "adult fiction", "general fiction",
        "social fiction", "psychological fiction", "family sagas", "multigenerational fiction",
        "feel-good fiction", "urban life fiction", "holiday fiction", "death, grief & bereavement fiction",
        "coming of age", "coming of age fiction", "frauenliteratur - familienleben", "british literature",
        "russian literature", "russian & soviet literature", "polish literature", "italian literature",
        "french literature", "spanish literature", "spanish & portuguese literature",
        "scandinavian literature", "african literature", "asian literature", "latin american",
        "canadian literature", "hungarian literature", "chinese", "u.s.", "literary criticism",
    ]

    /// The fixed table: normalized category → targets. If a category is listed here, only that
    /// applies — "Comic Fantasy" is Fantasy and Humor, not Comic; "Alternate History" is
    /// Science-Fiction, not Nonfiction.
    static let table: [String: [String]] = {
        var t: [String: [String]] = [:]
        func set(_ targets: [String], _ lookupKey: String...) {
            for s in lookupKey { t[s] = targets }
        }
        set(
            [fantasy], "fantasy", "military fantasy", "fantasy anthologies", "epic fantasy", "high fantasy",
            "dark fantasy", "historical fantasy", "urban fantasy", "science fiction fantasy",
            "science fiction & fantasy", "fantasy & science fiction", "sci fi fantasy", "speculative fiction",
            "roman-fantasy", "roman-fantasy-vampir", "paranormal", "supernatural", "magic", "vampires",
            "witches", "demons", "angels", "shapeshifters", "werewolves", "dragons", "drachen", "zwerge",
            "seelen", "mermaids", "fairy tales", "retellings", "gaslamp fantasy", "sword & sorcery",
            "sword and sorcery", "low fantasy", "epic", "epics", "epen", "christian fantasy",
            "greco-roman myth & legend fantasy", "gamelit & litrpg fiction", "fantasy fiction; american")
        set([fantasy, humor], "comic fantasy", "humorous fantasy", "roman-fantasy-heiter", "dationfur")
        set(
            [fantasy, romance], "romantic fantasy", "fantasy romance", "romantasy",
            "paranormal vampire romance", "paranormal romance")
        set([fantasy, historical], "arthurian")
        set(
            [scienceFiction], "science fiction", "science-fiction", "sf", "sci-fi", "trivial-sf",
            "hard science fiction", "military science fiction", "alternate history", "alternative history",
            "science fiction alternate history", "dystopia", "dystopian", "post apocalyptic",
            "post-apocalyptic", "apocalyptic", "space", "space opera", "aliens", "alien invasion",
            "first contact", "time travel", "futuristic", "generationenschiff", "siedler",
            "siedlerraumschiff", "klone", "raumfahrt", "künstliche intelligenz", "dystopian science fiction",
            "science fiction space operas", "first contact science fiction", "science fiction anthologies",
            "science fiction short stories", "steampunk", "blom liwikia",
            "science fiction - miakus - liwikia")
        set([scienceFiction, humor], "humorous science fiction")
        set([scienceFiction, crime], "science fiction crime & mystery")
        set([scienceFiction, romance], "science fiction romance")
        set([scienceFiction, adventure], "science fiction adventure")
        set(
            [crime], "mystery", "mysteries", "crime", "thriller", "thrillers", "suspense", "detective",
            "detektiv", "noir", "krimi", "kriminalroman", "kriminalliteratur", "krimis & thriller",
            "krimi/thriller", "thriller/krimi", "crime, thriller & mystery adventures",
            "crime, thriller & mystery", "mystery & detective", "international mystery & crime",
            "psychological & suspense", "nordic noir", "cozy", "cosy crime", "preibleirn rosipu",
            "gliobrousarn respaitret", "wissenschaftsthriller", "militär-thriller", "techno thrillers",
            "legal thrillers", "domestic thrillers", "procedural", "amateur sleuths", "espionage",
            "spy stories & tales of intrigue", "spy thriller")
        set([horror, crime], "horror thriller")
        set([romance, crime], "romantic suspense")
        set([crime, adventure], "thriller & suspense action fiction")
        set(
            [horror], "horror", "american horror", "u.s. horror fiction",
            "horror - us-amerikanische literatur", "endzeit horror", "psychological horror",
            "horror occult & supernatural", "horror & supernatural", "monsters & creatures horror", "grusel",
            "horror tales", "ghosts", "monsters", "zombies", "gothic"
        )
        set([horror, shortStories], "horror collections & anthologies")
        set(
            [romance], "romance", "contemporary romance", "chick lit", "rioploumi", "category romance",
            "erotica", "erotic literature & fiction", "smut", "enemies to lovers", "fake dating",
            "m m romance", "gay romance", "lesbian romance", "dark romance")
        set(
            [historical], "historical", "historical fiction", "historische romane",
            "historical fiction anthologies")
        set([historical, shortStories], "historical fiction short stories")
        set(
            [adventure], "action", "adventure", "westerns", "survival", "war", "military fiction",
            "adventure stories & action", "lgbtq+ action & adventure fiction")
        set([humor], "humor", "comedy", "satire", "humorous fiction")
        set([classics], "classics", "fiction classics")
        set([youngAdult], "young adult", "teen", "young adult fiction", "jugendbücher")
        set(
            [children], "middle grade", "childrens", "kinderbücher", "picture books",
            "education & reference for children")
        set(
            [nonfiction], "nonfiction", "science", "popular science", "history", "microhistory",
            "general history of the middle ages", "holocaust", "religion", "theology", "spirituality",
            "christian", "philosophy", "psychology", "psychology & psychiatry", "self help",
            "personal development", "politics", "mathematics", "programming", "computer science", "computers",
            "technology", "internet", "essays", "travel writing", "travel pictorials", "asia travel",
            "home & garden", "parenting", "textbooks & study guides",
            "education & reference material for young adults", "sports", "baseball", "music",
            "arts & photography", "arts & literature", "art criticism & theory", "art museums",
            "other art media & techniques", "film theory", "film guides & reviews", "cinema & film",
            "world cinema", "true crime", "corporate culture", "communication & relations", "pope & papacy",
            "lexikon", "alchemy", "occult", "new age ufos", "space exploration",
            "criticism on poetry & poets", "theatre", "mythology", "mythology & folk tales",
            "celtic & british isles mythology")
        set(
            [biography], "biography", "memoir", "biography memoir", "biographies & memoirs", "true story",
            "biografie/erfahrungen", "philosopher biographies", "scientist biographies",
            "film director biographies", "historical biographies")
        set(
            [comic], "manga", "comics", "comics manga", "seinen", "graphic novels",
            "comics & graphic novels by genre", "super-hero graphic novels", "superheroes", "ciswos")
        set([comic, historical, youngAdult], "historical fiction comics & graphic novels for young adults")
        set(
            [shortStories], "short stories", "novella", "anthologies", "anthologie", "collections",
            "kurzgeschichten", "short story collection", "fiction anthologies", "popular anthologies",
            "literary anthologies & collections",
            "kouflauter pandrigrour collective 2002 unpublished rare short stories collection")
        set([poetry], "poetry", "american poetry", "russian & soviet poetry", "plays")
        set([novel], "christian fiction")
        return t
    }()

    /// Keywords for everything not in the table — Amazon combines freely ("Ghost Thrillers",
    /// "Fantasy Romance for Young Adults"). A single word matches at a word start ("myster" →
    /// Mystery, Mysteries), several words as part of the string. All hits count; "Ghost
    /// Thrillers" is Horror and Crime.
    static let keywords: [(String, [String])] = [
        ("young adult", [youngAdult]), ("teen", [youngAdult]), ("jugend", [youngAdult]),
        ("coming of age", [novel]), ("coming-of-age", [novel]),
        ("children", [children]), ("kinder", [children]),
        ("fantasy", [fantasy]), ("wizard", [fantasy]), ("witch", [fantasy]), ("vampire", [fantasy]),
        ("dragon", [fantasy]), ("paranormal", [fantasy]), ("supernatural", [fantasy]), ("myth", [fantasy]),
        ("fairy", [fantasy]), ("isekai", [fantasy]), ("litrpg", [fantasy]), ("übernatürlich", [fantasy]),
        ("parapsychologie", [fantasy]), ("psychic", [fantasy]),
        ("science fiction", [scienceFiction]), ("sci-fi", [scienceFiction]), ("sci fi", [scienceFiction]),
        ("space", [scienceFiction]), ("alien", [scienceFiction]), ("dystopi", [scienceFiction]),
        ("apocalyp", [scienceFiction]), ("cyberpunk", [scienceFiction]), ("mecha", [scienceFiction]),
        ("thriller", [crime]), ("suspense", [crime]), ("myster", [crime]), ("crime", [crime]),
        ("krimi", [crime]),
        ("detect", [crime]), ("detekt", [crime]), ("noir", [crime]), ("spy", [crime]), ("police", [crime]),
        ("murder", [crime]), ("serial killer", [crime]), ("sleuth", [crime]), ("hard-boiled", [crime]),
        ("private investigator", [crime]),
        ("horror", [horror]), ("ghost", [horror]), ("geister", [horror]), ("zombie", [horror]),
        ("monster", [horror]), ("demon", [horror]), ("gothic", [horror]), ("grusel", [horror]),
        ("romanc", [romance]), ("romant", [romance]), ("erotic", [romance]),
        ("liebes", [romance]),
        ("historical", [historical]), ("historisch", [historical]),
        ("adventure", [adventure]), ("abenteuer", [adventure]), ("action", [adventure]),
        ("western", [adventure]),
        ("humor", [humor]), ("humour", [humor]), ("comedy", [humor]), ("satir", [humor]), ("heiter", [humor]),
        ("classic", [classics]), ("klassiker", [classics]),
        ("biograph", [biography]), ("biografie", [biography]), ("memoir", [biography]),
        ("autobiograph", [biography]),
        ("manga", [comic]), ("comics", [comic]), ("graphic novel", [comic]), ("superhero", [comic]),
        ("super-hero", [comic]), ("shounen", [comic]), ("shonen", [comic]), ("seinen", [comic]),
        ("short stor", [shortStories]), ("anthologi", [shortStories]),
        ("collection", [shortStories]),
        ("novella", [shortStories]), ("kurzgeschichte", [shortStories]),
        ("poetry", [poetry]), ("lyrik", [poetry]), ("poems", [poetry]),
        ("nonfiction", [nonfiction]), ("non-fiction", [nonfiction]), ("sachbuch", [nonfiction]),
        ("philosoph", [nonfiction]), ("religio", [nonfiction]), ("politic", [nonfiction]),
        ("psychology", [nonfiction]),
        ("textbook", [nonfiction]), ("essay", [nonfiction]), ("travel", [nonfiction]),
    ]

    /// What a single category yields.
    enum Hit: Equatable {
        case noise
        case genres([String])
        case general
        case raw(String)
    }

    /// Lowercased, without store suffix, without edges.
    static func normalized(_ category: String) -> String {
        var s = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in suffixes where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Ends in a number after at least one word: publisher number ("Klufluve 3926"), volume ("Das
    /// JIOSSKOHAI (Band 3)", "Woromur & Vaibou 03"), prize ("Silver Lantern Prize 1972") — the category describes a
    /// book, not a genre.
    static func endsWithNumber(_ s: String) -> Bool {
        let share = s.split { $0 == " " || $0 == "(" || $0 == ")" }
        guard share.count > 1, let lastWord = share.last else { return false }
        return lastWord.allSatisfy(\.isNumber)
    }

    static func hit(_ category: String) -> Hit {
        let s = normalized(category)
        if s.isEmpty || noise.contains(s) || endsWithNumber(s) { return .noise }
        if let targets = table[s] { return .genres(targets) }
        if general.contains(s) { return .general }
        let words = s.split { !$0.isLetter && !$0.isNumber }
        var found: [String] = []
        for (keyword, targets) in keywords {
            let compound = keyword.contains(" ") || keyword.contains("-")
            let matches = compound ? s.contains(keyword) : words.contains { $0.hasPrefix(keyword) }
            if matches { for z in targets where !found.contains(z) { found.append(z) } }
        }
        if !found.isEmpty { return .genres(found) }
        return .raw(category.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The genres of a book from its raw categories, in order of first appearance, without
    /// duplicates: first the narrative genres, otherwise the weak ones, otherwise `novel` (if a
    /// general category was present) — and raw unknowns always at the end.
    static func map(_ categories: [String]) -> [String] {
        var strong: [String] = []
        var weakOnes: [String] = []
        var unknown: [String] = []
        var hasGeneral = false
        for k in categories {
            switch hit(k) {
            case .noise: continue
            case .general: hasGeneral = true
            case .raw(let r): if !unknown.contains(r) { unknown.append(r) }
            case .genres(let targets):
                for z in targets where !discarded.contains(z) {
                    if weakTargets.contains(z) {
                        if !weakOnes.contains(z) { weakOnes.append(z) }
                    } else if !strong.contains(z) {
                        strong.append(z)
                    }
                }
            }
        }
        var result = strong.isEmpty ? weakOnes : strong
        if result.isEmpty && hasGeneral { result = [novel] }
        for r in unknown where !result.contains(r) { result.append(r) }
        return result
    }
}
