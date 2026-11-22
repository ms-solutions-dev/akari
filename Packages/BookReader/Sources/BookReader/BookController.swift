import Bedrock
import Foundation
import Observation
import PerformanceDiagnostics
import ReadiumNavigator
import ReadiumShared
import SourcesKit
import UIKit

/// The book on the main actor: opens with Readium, holds the navigator, converts
/// locators to pages and CFIs, and reports positions. The view asks here
/// for numbers and calls paging, jumping and searching.
///
/// **Pages are Readium positions** - 1024 characters per "page", the same on every
/// device. A PDF counts real pages.
@MainActor
@Observable
public final class BookController: NSObject {

    public enum Phase: Equatable {
        case opens
        case ready
        case failure(String)
    }

    public struct ContentEntry: Identifiable, Hashable {
        public let id: Int
        public let name: String
        public let depth: Int
        let href: String
        let link: Link
        /// The entry in the reading order in which the chapter begins.
        let resource: Int?
    }

    public struct Hit: Identifiable {
        public let id: Int
        public let before: String
        public let text: String
        public let after: String
        public let chapter: String?
        let locator: Locator
    }

    public let book: ReaderBook
    public let style: ReadingStyle
    public private(set) var phase: Phase = .opens
    public private(set) var navigator: UIViewController?
    /// Increments when the reader is pulled down from the very top in scroll mode - the reader closes
    /// (``TopPull``).
    public private(set) var closeRequest = 0
    @ObservationIgnored private var topPull: TopPull?
    public private(set) var isPdf = false
    public private(set) var rightToLeft = false

    public private(set) var page = 0
    public private(set) var count = 0
    public private(set) var fraction: Double = 0
    public private(set) var chapter: String?
    public private(set) var remainingInChapter: Int?
    public private(set) var content: [ContentEntry] = []
    public private(set) var currentEntry: ContentEntry?
    /// Where the last jump came from - the "back to page x" arrow.
    public private(set) var returnJump: (page: Int, locator: Locator)?
    /// A footnote as HTML while its sheet is open.
    public var footnote: String?
    /// The book's glossary, if it has one - searched across the whole book, before the
    /// navigator.
    public private(set) var glossary: Glossary?
    /// Where each term appears in the book - counted in the background once the reader is up.
    /// Basis for the marking plan, the sheet state and spoiler protection.
    public private(set) var terms: TermIndex?
    /// The book's maps with the terms labelled on them - searched after counting.
    public private(set) var cards: [BookCard] = []

    /// The word position of the current spot - for "up to here 19 times" and spoiler protection.
    /// From chapter and fraction within it; precise enough, since the rules count in thousands of words.
    public var wordHere: Int? {
        guard let terms, let layout else { return nil }
        return terms.word(href: layout.href.string, fraction: layout.locations.progression ?? 0)
    }

    /// "Chapter 3 - The Guild": the name of the chapter containing a word position:
    /// the title from the table of contents, otherwise the number in reading order.
    public func chapterName(word: Int) -> String? {
        guard let i = terms?.chapterIndex(word: word) else { return nil }
        // Only entries with a resource: one outside the reading order would otherwise end up last.
        return content.last { $0.resource.map { $0 <= i } ?? false }?.name
            ?? Wording.phrase("glossary.chapterNumber", i + 1)
    }
    /// The tapped term - the view shows its sheet.
    public var glossaryHits: Glossary.Item?
    /// The box through which chapters receive their terms while loading.
    private let box = GlossaryBox(hint: String(localized: "glossary.explanationOpen", bundle: .main))
    /// Counts taps by source so the same finger is not counted twice (``PointerGuard``).
    private let pointerGuard = PointerGuard()
    public private(set) var atEnd = false
    /// The reader was tapped - point in the navigator's area.
    public var tip: ((CGPoint, CGSize) -> Void)?
    public var pressedKey: ((Key) -> Void)?

    private var publication: Publication?
    private var spineCard: SpineCard?
    private var positions: [[Locator]] = []
    /// Characters per entry of the reading order - the basis of the screen pages.
    private var character: [Int] = []
    /// Characters per screen page from the samples of the measured chapters
    /// (``PageDensity``); `nil` until the first full sample - until then
    /// Readium's positions (1024 characters) count.
    private var density: Double?
    private var samples = PageDensity()
    private var pageInChapter = 0
    private var pagesInChapter = 0
    private var currentResource: Int?
    private var metering: Task<Void, Never>?
    private var pending: [BookLocation.Step]?
    private var priorJump: Locator?
    private var dark = false
    /// Wide size class (iPad) and landscape - for the column count (``ReadingStyle/columns``).
    private var wide = false
    private var landscape = false
    private var searchGroup: DecorationGroup = "suche"
    private var lastReport: ReportedSpot?

    public init(book: ReaderBook, style: ReadingStyle) {
        self.book = book
        self.style = style
    }

    private var epub: EPUBNavigatorViewController? { navigator as? EPUBNavigatorViewController }
    private var pdf: PDFNavigatorViewController? { navigator as? PDFNavigatorViewController }

    /// Readium's `Publication` is not `Sendable`, its services are `async` and
    /// run off the main actor - Swift 6 requires a handover for every call.
    /// The wrapper states: the object is built to be asked from anywhere
    /// (Readium synchronizes internally), and still stays owned here.
    private struct Halter: @unchecked Sendable {
        let value: Publication
    }

    private var halter: Halter? { publication.map(Halter.init) }

    /// Pages forward - and reports to performance diagnostics when a single page turn took longer than
    /// 300 ms.
    private func before(_ options: NavigatorGoOptions) async -> Bool {
        let startTime = ContinuousClock.now
        defer {
            let duration = ContinuousClock.now - startTime
            if duration > .milliseconds(300) {
                Performance.remark("Paging took \(Int(duration / .milliseconds(1))) ms")
            }
        }
        if let epub { return await epub.goForward(options: options) }
        if let pdf { return await pdf.goForward(options: options) }
        return false
    }

    private func back(_ options: NavigatorGoOptions) async -> Bool {
        if let epub { return await epub.goBackward(options: options) }
        if let pdf { return await pdf.goBackward(options: options) }
        return false
    }

    private func go(to locator: Locator) async -> Bool {
        let options = NavigatorGoOptions(animated: false)
        if let epub { return await epub.go(to: locator, options: options) }
        if let pdf { return await pdf.go(to: locator, options: options) }
        return false
    }

    private func go(to link: Link) async -> Bool {
        let options = NavigatorGoOptions(animated: false)
        if let epub { return await epub.go(to: link, options: options) }
        if let pdf { return await pdf.go(to: link, options: options) }
        return false
    }

    private var layout: Locator? { epub?.currentLocation ?? pdf?.currentLocation }

    // MARK: - Opening

    public func open(dark: Bool) async {
        self.dark = dark
        setLine()
        guard navigator == nil else { return }
        do {
            let opened = try await BookOpener.open(book.file, box: box)
            let publication = opened.publication
            self.publication = publication
            spineCard = opened.spineCard
            isPdf = opened.isPdf
            rightToLeft = publication.metadata.readingProgression == .rtl
            let halter = Halter(value: publication)
            positions = (try? await halter.value.positionsByReadingOrder().get()) ?? []
            count = positions.reduce(0) { $0 + $1.count }
            let start = await startLocator(halter)
            content = await loadTableOfContents(halter)
            // The glossary before the navigator: the chapters the web view is about to load
            // should already carry their terms.
            if !isPdf {
                if let persistence = TermCache.load(for: book.file) {
                    // Already computed: read nothing, search nothing, recognize nothing.
                    glossary = persistence.glossary
                    box.set(glossary, to: style.glossary)
                    let box = box, on = self.opened
                    Task { [weak self] in
                        if let chapter = persistence.chapterIndex {
                            let chapterIndex = TermIndex(chapter: chapter)
                            box.setPlan(
                                await BookController.plane(
                                    chapterIndex, glossary: persistence.glossary, opened: on))
                            self?.terms = chapterIndex
                        }
                        self?.cards = await BookController.loadCards(halter, persistence.cards)
                    }
                } else {
                    // Read raw once: after `box.set` the publication yields marked-up HTML.
                    let chapter = await BookController.chapterHTML(halter)
                    let title = chapterTitle(halter)
                    glossary = await BookController.findGlossary(chapter, title: title)
                    // Which forms are common words? Once per book, then stored.
                    if var g = glossary {
                        g.general = await BookController.dictionary(
                            Set(
                                g.entries.flatMap(\.forms).filter { !$0.contains(" ") }.map {
                                    $0.lowercased()
                                }))
                        glossary = g
                    }
                    box.set(glossary, to: style.glossary)
                    let found = glossary
                    let box = box, on = self.opened
                    // Counting, planning and maps in the background - the book does not open later.
                    // Chapters that load beforehand mark the first mention of each term.
                    Task { [weak self] in
                        if let found {
                            let chapterIndex = await BookController.countTerms(chapter, glossary: found)
                            box.setPlan(
                                await BookController.plane(chapterIndex, glossary: found, opened: on))
                            self?.terms = chapterIndex
                        }
                        // Then the maps: on-device text recognition, about a second per image.
                        // Without a glossary, images named like a map and the map section remain.
                        let cards = await BookController.findCards(
                            halter, chapter: chapter, glossary: found ?? .empty, title: title)
                        self?.cards = cards
                        await self?.addCardNames(cards, chapter: chapter)
                        self?.storeTerms()
                    }
                }
                if let glossary {
                    Diagnostics.step(
                        "Glossary: \(glossary.entries.count) terms under “\(glossary.heading)”",
                        since: nil,
                        area: "Reader")
                    #if DEBUG
                        // `AKARI_GLOSSAR=<term>` opens the glossary sheet for that term ten seconds after loading,
                        // for screenshots: an XCUITest tap into the web view does not register as a
                        // term tap, a real finger does. Debug builds only.
                        if let probe = ProcessInfo.processInfo.environment["AKARI_GLOSSAR"],
                            let entry = glossary.entries.first(where: { $0.term.hasPrefix(probe) })
                                ?? glossary.entries.first
                        {
                            Task { [weak self] in
                                try? await Task.sleep(for: .seconds(10))
                                self?.glossaryHits = entry
                            }
                        }
                    #endif
                }
            }
            if isPdf {
                let n = try PDFNavigatorViewController(
                    publication: publication, initialLocation: start,
                    config: .init(preferences: style.pdfPreferences(dark: dark)))
                n.delegate = self
                navigator = n
            } else {
                let n = try EPUBNavigatorViewController(
                    publication: publication, initialLocation: start,
                    config: .init(
                        preferences: style.presets(dark: dark, wide: wide, landscape: landscape),
                        editingActions: EditingAction.defaultActions + [BookController.menuSearch],
                        contentInset: [.compact: (top: 40, bottom: 44), .regular: (top: 56, bottom: 56)]))
                n.delegate = self
                navigator = n
                n.addObserver(pointerGuard)
                topPull = TopPull(
                    to: n.view, active: { [weak self] in self?.style.reflowing == true },
                    trigger: { [weak self] in self?.closeRequest += 1 })
            }
            phase = .ready
            // Paging test without a finger (simulator): AKARI_BLAETTERPROBE=<seconds> pages forward
            // at that interval - for performance diagnostics, as in the comic reader.
            if let beat = Double(ProcessInfo.processInfo.environment["AKARI_BLAETTERPROBE"] ?? "") {
                Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(beat))
                        guard let self else { return }
                        self.proceed()
                    }
                }
            }
            // Tap test without a finger (simulator): AKARI_TIPPPROBE=1 taps into the middle every 1.5 s
            // and logs whether the tap arrived.
            if ProcessInfo.processInfo.environment["AKARI_TIPPPROBE"] != nil,
                let n = navigator as? VisualNavigator
            {
                Task { [weak self] in
                    for i in 1...10 {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard let self else { return }
                        let center = CGPoint(x: n.view.bounds.midX, y: n.view.bounds.midY)
                        // After three taps a jump far back (as with the slider), after
                        // six one page turn - then keep tapping.
                        if i == 4 {
                            Diagnostics.step("Tap probe: jump to 90 %", since: nil, area: "Reader")
                            self.jump(fraction: 0.9)
                            continue
                        }
                        if i == 7 {
                            Diagnostics.step("Tap probe: continue", since: nil, area: "Reader")
                            self.proceed()
                            continue
                        }
                        Diagnostics.step("Tap probe \(i): sent", since: nil, area: "Reader")
                        self.navigator(n, didTapAt: center)
                    }
                }
            }
            if !isPdf { character = await BookController.countCharacters(halter) }
            computePages()
        } catch {
            Diagnostics.network.error("Book not opened: \(String(describing: error), privacy: .public)")
            phase = .failure(String(describing: error))
        }
    }

    /// Where to start: the CFI from the saved state, otherwise the fraction, otherwise the front.
    private func startLocator(_ halter: Halter) async -> Locator? {
        switch book.start {
        case .position(let cfi, let fraction):
            if let spot = BookLocation(cfi: cfi), let locator = locator(for: spot, halter.value) {
                pending = spot.steps.isEmpty ? nil : spot.steps
                Diagnostics.step("Start at \(cfi)", since: nil, area: "Reader")
                return locator
            }
            return await halter.value.locate(progression: fraction)
        case .fraction(let fraction):
            return await halter.value.locate(progression: fraction)
        case .page(let n, _):
            let flat = positions.flatMap { $0 }
            return flat.indices.contains(n - 1) ? flat[n - 1] : nil
        case .second, nil:
            return nil
        }
    }

    private func locator(for spot: BookLocation, _ publication: Publication) -> Locator? {
        let link: Link? =
            if let card = spineCard, let href = card.href(for: spot.entry) {
                publication.readingOrder.first { SpineCard.equal($0.url().string, href) }
            } else if publication.readingOrder.indices.contains(spot.entry) {
                publication.readingOrder[spot.entry]
            } else {
                nil
            }
        guard let link else { return nil }
        return Locator(
            href: link.url(), mediaType: link.mediaType ?? .xhtml, locations: .init(progression: 0))
    }

    private func loadTableOfContents(_ halter: Halter) async -> [ContentEntry] {
        let tree = (try? await halter.value.tableOfContents().get()) ?? []
        let publication = halter.value
        var list: [ContentEntry] = []
        func collect(_ links: [Link], depth: Int) {
            for link in links {
                let href = link.url().string
                list.append(
                    ContentEntry(
                        id: list.count, name: link.title ?? href, depth: depth, href: href, link: link,
                        resource: resource(for: href, publication)))
                collect(link.children, depth: depth + 1)
            }
        }
        collect(tree, depth: 0)
        return list
    }

    private func resource(for href: String, _ publication: Publication) -> Int? {
        let without = href.split(separator: "#").first.map(String.init) ?? href
        return publication.readingOrder.firstIndex(where: { SpineCard.equal($0.url().string, without) })
    }

    /// The page on which a contents entry begins - by the current density.
    public func page(from entry: ContentEntry) -> Int? {
        guard let i = entry.resource else { return nil }
        return pagesBefore(i) + 1
    }

    // MARK: - Screen pages

    /// The characters per entry - once on opening, in the background: markup
    /// removed, whitespace collapsed, counted.
    nonisolated private static func countCharacters(_ halter: Halter) async -> [Int] {
        var list: [Int] = []
        for link in halter.value.readingOrder {
            let data = (try? await halter.value.get(link)?.read().get()) ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            text = text.replacingOccurrences(
                of: "<head>[\\s\\S]*?</head>", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            list.append(max(text.count, 1))
        }
        return list
    }

    /// Pages before entry `i` - with density from the characters, otherwise from the positions.
    private func pagesBefore(_ i: Int) -> Int {
        if let density, character.count > i {
            return character[..<i].reduce(0) { $0 + Int((Double($1) / density).rounded(.up)) }
        }
        return positions[..<min(i, positions.count)].reduce(0) { $0 + $1.count }
    }

    /// "Page x of y" like Apple Books: screen pages that follow
    /// font and window - measured in the visible document (pages and
    /// characters there), extrapolated to the whole book via the characters per entry.
    /// The position sent to the server is unaffected (CFI and fraction).
    private func computePages() {
        guard let density, !character.isEmpty, let i = currentResource, character.indices.contains(i) else {
            // Before the first measurement: Readium's positions.
            count = positions.reduce(0) { $0 + $1.count }
            return
        }
        count = character.reduce(0) { $0 + Int((Double($1) / density).rounded(.up)) }
        page = min(pagesBefore(i) + pageInChapter, count)
        remainingInChapter = max(pagesInChapter - pageInChapter, 0)
    }

    /// Measures in the visible document: pages, characters, current page - after every
    /// page turn and every style change (then shortly later, once re-laid out).
    private func measurePages(delayed: Bool = false) {
        guard let epub else { return }
        metering?.cancel()
        metering = Task { [weak self] in
            if delayed { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled, let self else { return }
            guard case .success(let value) = await epub.evaluateJavaScript(BookController.jsPages),
                let list = value as? [Any], list.count == 3,
                let n = (list[0] as? NSNumber)?.intValue, let t = (list[1] as? NSNumber)?.intValue,
                let p = (list[2] as? NSNumber)?.intValue, n > 0
            else { return }
            pagesInChapter = n
            pageInChapter = min(max(p + 1, 1), n)
            // Only a full chapter counts as a sample; otherwise the density stays as
            // it was - a title page must not push the book to 78,000 pages.
            if let i = currentResource, character.indices.contains(i) {
                samples.take(chapter: i, character: character[i], pages: n)
            } else if t > 0 {
                samples.take(chapter: -1, character: t, pages: n)
            }
            if let value = samples.value { density = value }
            computePages()
        }
    }

    /// Columns (paging) or height (scrolling): count, characters, zero-based page.
    static let jsPages = """
        (function(){
          var s=document.scrollingElement||document.documentElement;
          var scroll=document.documentElement.style.getPropertyValue('--USER__view')=='readium-scroll-on';
          var w=window.innerWidth,h=window.innerHeight;
          var n=scroll?Math.max(1,Math.round(s.scrollHeight/h)):Math.max(1,Math.round(s.scrollWidth/w));
          var p=scroll?Math.round(window.scrollY/h):Math.round(Math.abs(window.scrollX)/w);
          var t=(document.body.innerText||'').length;
          return [n,t,p];
        })()
        """

    // MARK: - Paging

    /// Whether pages turn with a transition - the setting and the accessibility option "Reduce Motion".
    private var withTransition: Bool { style.animation && !UIAccessibility.isReduceMotionEnabled }

    /// How long the custom transition lasts.
    static let transition: TimeInterval = 0.2

    /// **Paging with its own short transition**: Readium's page-turn animation took
    /// about 620 ms per page when measured, under 300 ms without it - that felt sluggish.
    /// Now Readium pages without animation, and over it an image of the old page slides
    /// away a short distance in reading direction within ``transition`` and fades out; the new one
    /// is already underneath. Swiping with the finger stays Readium's - there the finger leads.
    private func turnPage(forward: Bool) async -> Bool {
        let without = NavigatorGoOptions(animated: false)
        guard withTransition, let hostView = navigator?.view,
            let image = hostView.snapshotView(afterScreenUpdates: false)
        else {
            return forward ? await before(without) : await back(without)
        }
        image.frame = hostView.bounds
        image.isUserInteractionEnabled = false
        hostView.addSubview(image)
        let turned = forward ? await before(without) : await back(without)
        guard turned else {
            image.removeFromSuperview()
            return false
        }
        // Forward, the old page slides out against the reading direction - for manga-style
        // books, from right to left that means to the right.
        let direction: CGFloat = forward != rightToLeft ? -1 : 1
        UIView.animate(withDuration: Self.transition, delay: 0, options: [.curveEaseOut]) {
            image.transform = CGAffineTransform(translationX: direction * hostView.bounds.width * 0.3, y: 0)
            image.alpha = 0
        } completion: { _ in
            image.removeFromSuperview()
        }
        return true
    }

    /// Pages forward; if that fails the book has ended - but only if the last
    /// chapter is open and a second attempt after the page turn yields nothing either:
    /// Readium also says "no" while a page is still in motion, and a tap
    /// mid-turn used to raise "book finished" that way.
    public func proceed() {
        Task {
            if await turnPage(forward: true) { return }
            let lastIndex = (publication?.readingOrder.count ?? 0) - 1
            guard isPdf || currentResource == lastIndex else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if !(await turnPage(forward: true)) { atEnd = true }
        }
    }

    public func back() {
        if atEnd {
            atEnd = false
            return
        }
        Task { _ = await turnPage(forward: false) }
    }

    /// The slider - a fraction of the whole book.
    public func jump(fraction: Double) {
        let flat = positions.flatMap { $0 }
        guard !flat.isEmpty else { return }
        let index = min(max(Int((Double(flat.count - 1) * fraction).rounded()), 0), flat.count - 1)
        rememberJump()
        Task { _ = await go(to: flat[index]) }
    }

    public func jump(to entry: ContentEntry) {
        rememberJump()
        Task { _ = await go(to: entry.link) }
    }

    public func jumpBack() {
        guard let target = returnJump else { return }
        returnJump = nil
        Task { _ = await go(to: target.locator) }
    }

    private func rememberJump() {
        priorJump = layout
    }

    /// From how many pages on a jump gets the back arrow.
    static let jumpBackFrom = 10

    // MARK: - Style

    public func adopt(dark: Bool) {
        self.dark = dark
        setLine()
        epub?.submitPreferences(style.presets(dark: dark, wide: wide, landscape: landscape))
        pdf?.submitPreferences(style.pdfPreferences(dark: dark))
        samples.clearOut()
        measurePages(delayed: true)
    }

    /// The window changed (rotation, split view): Readium re-lays out, the
    /// screen pages are only right after a new measurement. If the column
    /// count changes with size or size class (iPad: one in portrait,
    /// two in landscape), the preferences go to Readium once more.
    public func windowChanged(size: CGSize, wide: Bool) {
        let previously = style.columnCount(wide: self.wide, landscape: landscape)
        self.wide = wide
        landscape = size.width > size.height
        guard !isPdf else { return }
        if style.columnCount(wide: wide, landscape: landscape) != previously {
            epub?.submitPreferences(style.presets(dark: dark, wide: wide, landscape: landscape))
        }
        samples.clearOut()
        measurePages(delayed: true)
    }

    // MARK: - Glossary

    /// Search the whole book for the glossary (rule `front`): at the front only a
    /// matching heading counts, which checks only the start of each chapter; at the end the form too.
    nonisolated private static func findGlossary(
        _ chapter: [(href: String, html: String)], title: [String: String]
    )
        async -> Glossary?
    {
        Glossary.find(in: chapter, title: title)
    }

    /// The marking plan off the main actor - after the `await` of counting it
    /// would otherwise run there while the reader builds the first page.
    nonisolated private static func plane(
        _ chapterIndex: TermIndex, glossary: Glossary?, opened: [String: Int]
    ) async -> [String: Set<Int>] {
        let types = Dictionary((glossary?.entries ?? []).map { ($0.id, $0.type) }) { a, _ in a }
        return MarkingPlan.compute(chapterIndex, types: types, opened: opened)
    }

    /// The reading position as a word position for "In the book" in the title detail (spoiler protection),
    /// saved when the reader closes.
    public func saveState() {
        guard let wordHere else { return }
        UserDefaults.standard.set(wordHere, forKey: "begriffe.stand." + book.id)
    }

    static func savedState(_ id: String) -> Int? {
        UserDefaults.standard.object(forKey: "begriffe.stand." + id) as? Int
    }

    /// Per term the word position at last opening, saved per book.
    @ObservationIgnored private lazy var opened: [String: Int] =
        UserDefaults.standard.dictionary(forKey: openedKey) as? [String: Int] ?? [:]
    private var openedKey: String { "begriffe.geoeffnet." + book.id }

    /// A term sheet opened: remember it and recompute the plan for the following chapters -
    /// the term is not marked again for 10,000 words, others take precedence.
    public func saveOpened(_ entry: Glossary.Item) {
        opened[entry.id] = wordHere ?? 0
        UserDefaults.standard.set(opened, forKey: openedKey)
        guard let terms else { return }
        let box = box, glossary = glossary, on = opened
        Task { box.setPlan(await BookController.plane(terms, glossary: glossary, opened: on)) }
    }

    /// All chapters of the reading order as (href, HTML), raw - read before `box.set`.
    nonisolated private static func chapterHTML(_ halter: Halter) async -> [(href: String, html: String)] {
        var chapter: [(href: String, html: String)] = []
        for link in halter.value.readingOrder {
            guard let data = try? await halter.value.get(link)?.read().get() else { continue }
            chapter.append((link.url().string, String(decoding: data, as: UTF8.self)))
        }
        return chapter
    }

    /// Store the computed state for the next opening (``TermCache``).
    private func storeTerms() {
        let persistence = TermCache(
            rules: TermCache.rules, glossary: glossary, chapterIndex: terms?.chapter,
            cards: cards.map { TermCache.Card(path: $0.name, places: $0.places) })
        let file = book.file
        Task.detached(priority: .utility) { persistence.write(for: file) }
    }

    /// Read the images of stored maps from the EPUB - without text recognition.
    nonisolated private static func loadCards(
        _ halter: Halter, _ cards: [TermCache.Card]
    ) async
        -> [BookCard]
    {
        var result: [BookCard] = []
        for k in cards {
            let encoded = k.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? k.path
            guard let url = RelativeURL(string: encoded),
                let data = try? await halter.value.get(url)?.read().get()
            else { continue }
            result.append(BookCard(data: data, name: k.path, places: k.places))
        }
        return result
    }

    /// Map names the glossary does not know are added as places: tappable from the
    /// next loaded chapter on and counted in the index. Without a glossary one arises
    /// from map names alone. Plan and glossary change together so the indices match.
    private func addCardNames(_ cards: [BookCard], chapter: [(href: String, html: String)]) async {
        let old = glossary
        let new = Set(cards.flatMap(\.places.keys)).subtracting(old?.entries.map(\.id) ?? []).sorted()
        guard !new.isEmpty else { return }
        var g = Glossary(
            heading: old?.heading ?? "",
            entries: (old?.entries ?? [])
                + new.map { Glossary.Item(term: $0, explanation: "", forms: [$0], type: .place) },
            chapter: old?.chapter ?? [])
        g.general = old?.general ?? []
        let chapterIndex = await BookController.countTerms(chapter, glossary: g)
        let plan = await BookController.plane(chapterIndex, glossary: g, opened: opened)
        glossary = g
        box.set(g, to: style.glossary)
        box.setPlan(plan)
        terms = chapterIndex
        Diagnostics.step("Maps: \(new.count) names as terms", since: nil, area: "Reader")
    }

    /// The words the dictionary knows (German, English) - they never become a map name.
    ///
    /// **With breathing room**: `UITextChecker` belongs on the main thread, and in one
    /// go the check held it for 714 ms when opening a long book. Fixed batches of 200 words
    /// still blocked it for 468 ms on iPhone - a word costs over a millisecond per
    /// language. Hence a time budget: after ``budget`` the main thread is free again.
    @MainActor static func dictionary(_ words: Set<String>) async -> Set<String> {
        let checker = UITextChecker()
        let languages = ["de_DE", "en_US"].filter { UITextChecker.availableLanguages.contains($0) }
        var known = Set<String>()
        var since = ContinuousClock.now
        for w in words {
            if ContinuousClock.now - since > budget {
                await Task.yield()
                since = ContinuousClock.now
            }
            let whole = NSRange(location: 0, length: (w as NSString).length)
            let inDictionary = languages.contains {
                checker.rangeOfMisspelledWord(in: w, range: whole, startingAt: 0, wrap: false, language: $0)
                    .location == NSNotFound
            }
            if inDictionary { known.insert(w) }
        }
        return known
    }

    /// How long ``dictionary(_:)`` checks in one go - one frame at 60 Hz.
    static let budget: Duration = .milliseconds(16)

    /// Find maps in the book, read their labels and match them with the terms
    /// (``BookCard``). A candidate from the book edge only counts with at least two terms.
    nonisolated private static func findCards(
        _ halter: Halter, chapter: [(href: String, html: String)], glossary: Glossary, title: [String: String]
    ) async -> [BookCard] {
        var cards: [BookCard] = []
        // Read the images once: first for the size of the candidates (rule `margin`), then
        // for text recognition.
        let read = ImageCache()
        func load(_ path: String) async -> Data? {
            if let d = await read.data[path] { return d }
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            guard let url = RelativeURL(string: encoded),
                let d = try? await halter.value.get(url)?.read().get()
            else { return nil }
            await read.create(d, for: path)
            return d
        }
        let selection = await CardFinder.selection(CardFinder.findings(in: chapter, title: title)) { path in
            await load(path).flatMap(CardFinder.edge)
        }
        // Keep only the chosen ones - the other candidates were read only for their size.
        await read.requestKeep(Set(selection.map(\.path)))
        guard !selection.isEmpty else { return [] }
        // For map names: the body text without the glossary itself, the forms of the glossary.
        let text = chapter.filter { k in !glossary.chapter.contains { SpineCard.equal($0, k.href) } }
            .map { CardFinder.visibleText($0.html) }.joined(separator: "\n")
        let known = Set(glossary.entries.flatMap(\.forms).map(CardFinder.folded))
        for fund in selection {
            guard let data = await load(fund.path), let image = CardFinder.image(data) else { continue }
            let labels = CardFinder.labels(image)
            let fromGlossary = CardFinder.match(labels, glossary: glossary)
            var places = fromGlossary
            let dictionary = await BookController.dictionary(CardFinder.words(in: labels))
            places.merge(
                CardFinder.names(labels, text: text, known: known, dictionary: dictionary)
            ) { old, _ in old }
            // Without recognized places the app only shows an image that is itself named like a map. Since the
            // file name of the page counts as a title ("..._map.xhtml"), ornaments
            // and vignettes on the map page also count as certain. A
            // candidate from the margin still needs two places - from the glossary: names from the body text
            // also appear on title pages, ads and text rendered as images; without
            // that, 1,447 margin images without a glossary would show up as "map". They only apply to fixed maps.
            // Without a glossary there is nothing to match: in the map section three recognized
            // labels suffice - decorative images on section pages carry none.
            let withoutGlossary =
                glossary.entries.isEmpty && fund.inCardPart
                && labels.filter { CardFinder.folded($0.text).count >= 3 }.count >= 3
            guard
                withoutGlossary
                    || (fund.certain ? (!places.isEmpty || fund.fromName) : fromGlossary.count >= 2)
            else {
                continue
            }
            cards.append(BookCard(data: data, name: fund.path, places: places))
        }
        return cards
    }

    /// Images already read per path - ``findCards`` needs them twice.
    private actor ImageCache {
        var data: [String: Data] = [:]
        func create(_ d: Data, for path: String) { data[path] = d }
        func requestKeep(_ paths: Set<String>) { data = data.filter { paths.contains($0.key) } }
    }

    /// Every mention of every term in the book with word position - without the glossary chapters themselves.
    /// The same pass as when marking, so the plan matches the mentions at load time.
    nonisolated private static func countTerms(
        _ raw: [(href: String, html: String)], glossary: Glossary
    ) async
        -> TermIndex
    {
        let chapter = raw.map { href, html -> TermIndex.Chapter in
            if glossary.chapter.contains(where: { SpineCard.equal($0, href) })
                || !GlossaryBox.isChapter(href)
            {
                return TermIndex.Chapter(href: href, words: 0, mentions: [])
            }
            let counted = Glossary.mentions(html: html, glossary: glossary)
            return TermIndex.Chapter(
                href: href, words: counted.words, mentions: counted.mentions)
        }
        return TermIndex(chapter: chapter)
    }

    /// Chapter titles from the table of contents per resource of the reading order - the
    /// first entry that begins in the resource names it.
    private func chapterTitle(_ halter: Halter) -> [String: String] {
        var title: [String: String] = [:]
        for entry in content {
            guard let i = entry.resource, i < halter.value.readingOrder.count else { continue }
            let href = halter.value.readingOrder[i].url().string
            if title[href] == nil { title[href] = entry.name }
        }
        return title
    }

    /// Toggles the marking - the switch in the Aa sheet. Chapters still
    /// loading get the state from the box; the visible one via script.
    public func adoptGlossary() {
        box.to = style.glossary
        box.pronounced = style.pronounced
        toggleGlossary()
    }

    /// The profile's accent color (light, dark) - for "Prominent" and the fill on tap.
    /// Which one applies is decided by the reading theme, not the system.
    public func setAccent(light: UInt32, dark: UInt32) {
        accentPair = (light, dark)
        setLine()
    }

    private var accentPair: (light: UInt32, dark: UInt32)?

    private func showAccent(_ hex: UInt32) {
        box.accent = hex
        guard let epub, glossary != nil else { return }
        Task {
            _ = await epub.evaluateJavaScript(
                "document.documentElement.style.setProperty('--ss-akzent','#\(String(format: "%06X", hex))')")
        }
    }

    /// Set or remove `html.ss-glossar-aus` in the visible chapter - on every
    /// chapter change, since neighboring chapters may be preloaded.
    private func toggleGlossary() {
        guard let epub, glossary != nil else { return }
        let from = !style.glossary, pronounced = style.pronounced
        Task {
            _ = await epub.evaluateJavaScript(
                "document.documentElement.classList.toggle('ss-glossar-aus', \(from));"
                    + "document.documentElement.classList.toggle('ss-deutlich', \(pronounced))")
        }
    }

    /// After a tap: did it hit a term? The marker in the chapter
    /// (`window.__ssBegriff`, set on `pointerdown`) tells.
    private func tappedTerm() async -> Glossary.Item? {
        guard let epub, let glossary, style.tap else { return nil }
        let result = await epub.evaluateJavaScript(
            "(function(){var b=window.__ssBegriff||null;window.__ssWahl=b?window.__ssEl:null;"
                + "window.__ssBegriff=null;return b;})()")
        guard case .success(let value) = result, let id = value as? String else { return nil }
        return glossary.entries.first { $0.id == id }
    }

    /// The line follows the reading theme: the box for new chapters, the visible one via script.
    private func setLine() {
        let theme = style.effectiveTheme(dark: dark)
        let hairline = theme.hairline
        box.hairline = hairline
        box.pronounced = style.pronounced
        if let accentPair { showAccent(theme.isDark ? accentPair.dark : accentPair.light) }
        guard let epub, glossary != nil else { return }
        Task {
            _ = await epub.evaluateJavaScript(
                "document.documentElement.style.setProperty('--ss-linie','\(hairline)%')")
        }
    }

    /// The fill around the tapped term while its sheet is open (accent
    /// 14 %, radius 3 pt, static) - `nil` removes it again with the sheet.
    public func highlightTerm(accent: UInt32?) {
        guard let epub, glossary != nil else { return }
        let route =
            "document.querySelectorAll('.ss-aktiv').forEach(function(e){e.classList.remove('ss-aktiv')});"
        let js =
            accent.map {
                "(function(){" + route + "var t=window.__ssWahl;if(!t)return;"
                    + "document.documentElement.style.setProperty('--ss-akzent','#"
                    + String(format: "%06X", $0)
                    + "');t.classList.add('ss-aktiv');})()"
            } ?? "(function(){" + route + "window.__ssWahl=null;})()"
        Task { _ = await epub.evaluateJavaScript(js) }
    }

    // MARK: - Search

    /// "Search in book" in the selection menu - for every word, even without a glossary.
    static var menuSearch: EditingAction {
        EditingAction(
            title: String(localized: "book.searchInBook", bundle: .main),
            action: #selector(NavigatorShell.Container.searchInBook(_:)))
    }

    /// The selected text - afterwards the selection is gone.
    public func takeSelection() -> String? {
        let text = epub?.currentSelection?.locator.text.highlight?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        epub?.clearSelection()
        return text?.isEmpty == false ? text : nil
    }

    public func search(_ text: String) async -> [Hit] {
        guard let halter, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard case .success(let run) = await halter.value.search(query: text) else { return [] }
        var hit: [Hit] = []
        while hit.count < 200, case .success(let collection?) = await run.next() {
            for l in collection.locators {
                hit.append(
                    Hit(
                        id: hit.count, before: l.text.before ?? "", text: l.text.highlight ?? text,
                        after: l.text.after ?? "", chapter: l.title, locator: l))
            }
        }
        return hit
    }

    public func show(_ hit: Hit) {
        rememberJump()
        Task {
            _ = await go(to: hit.locator)
            epub?.apply(
                decorations: [
                    Decoration(
                        id: "treffer", locator: hit.locator, style: .highlight(tint: .systemYellow))
                ], in: searchGroup)
        }
    }

    public func eraseMarking() {
        epub?.apply(decorations: [], in: searchGroup)
    }

    // MARK: - Position

    private func refresh(_ locator: Locator) {
        guard let publication else { return }
        fraction = locator.locations.totalProgression ?? 0
        let i = publication.readingOrder.firstIndex(where: {
            SpineCard.equal($0.url().string, locator.href.string)
        })
        if currentResource != i {
            currentResource = i
            toggleGlossary()
        }
        if density == nil || isPdf {
            page = locator.locations.position ?? page
            if let i, positions.indices.contains(i), let last = positions[i].last?.locations.position {
                remainingInChapter = max(last - page, 0)
            } else {
                remainingInChapter = nil
            }
        }
        if !isPdf { measurePages() }
        let href = locator.href.string.split(separator: "#").first.map(String.init) ?? locator.href.string
        currentEntry = content.last { $0.href.split(separator: "#").first.map(String.init) == href }
        chapter = locator.title ?? currentEntry?.name
        Performance.spot("\(chapter ?? "no chapter") · \(Int((fraction * 100).rounded())) %")
    }

    private func report(_ locator: Locator) {
        guard pending == nil else { return }
        let done = count > 0 && page >= count
        if isPdf {
            book.report(.page(max(page, 1), from: max(count, 1)), done)
            return
        }
        let fraction = fraction
        Task {
            let cfi = await determineCFI(locator)
            let spot = ReportedSpot(cfi: cfi, fraction: fraction)
            guard spot.isNew(after: lastReport) else { return }
            lastReport = spot
            book.report(.position(cfi: cfi, fraction: fraction), done)
        }
    }

    /// What the last report said, to send each spot only once.
    ///
    /// **Why the fraction counts too (22.11.2026):** the CFI names the first visible element,
    /// and a long paragraph fills several pages - and without an element Readium leaves only
    /// the chapter. Deduplicated by the CFI alone, the reader then stayed silent for whole
    /// chapters, the reading-time counter saw gaps over ten minutes, took them for pauses and
    /// counted an hour of reading as nothing. The fraction moves with every page.
    struct ReportedSpot: Equatable {
        let cfi: String
        let fraction: Double

        func isNew(after last: ReportedSpot?) -> Bool {
            guard let last else { return true }
            return cfi != last.cfi || abs(fraction - last.fraction) > 0.000_01
        }
    }

    /// The CFI of the visible spot - the element path from the document, the
    /// spine entry from the map.
    private func determineCFI(_ locator: Locator) async -> String {
        let entry: Int
        if let card = spineCard, let e = card.entry(for: locator.href.string) {
            entry = e
        } else {
            entry =
                publication?.readingOrder.firstIndex {
                    SpineCard.equal($0.url().string, locator.href.string)
                } ?? 0
        }
        var steps: [BookLocation.Step] = []
        if let epub, case .success(let value) = await epub.evaluateJavaScript(BookLocation.jsDetermine),
            let path = value as? String
        {
            steps = BookLocation.steps(from: path)
        }
        return BookLocation(entry: entry, steps: steps).cfi(spine: spineCard?.spineStep ?? 6)
    }
}

// MARK: - Readium callbacks

extension BookController: EPUBNavigatorDelegate, PDFNavigatorDelegate {

    public func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        refresh(locator)
        if let steps = pending {
            pending = nil
            Task {
                if let epub,
                    case .success(let value) = await epub.evaluateJavaScript(
                        BookLocation.jsJump(to: steps)),
                    (value as? Bool) != true
                {
                    Diagnostics.step(
                        "CFI position not found, chapter start — \(String(describing: value))", since: nil,
                        area: "Reader")
                }
            }
            return
        }
        report(locator)
    }

    public func navigator(_ navigator: Navigator, didJumpTo locator: Locator) {
        guard let from = priorJump else { return }
        priorJump = nil
        if let a = from.locations.position, let b = locator.locations.position,
            abs(a - b) >= BookController.jumpBackFrom
        {
            returnJump = (a, from)
        }
    }

    public func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        Diagnostics.network.error("Reader: \(String(describing: error), privacy: .public)")
    }

    public func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        UIApplication.shared.open(url)
    }

    public func navigator(
        _ navigator: Navigator, shouldNavigateToNoteAt link: Link, content: String, referrer: String?
    ) -> Bool {
        footnote = content
        return false
    }

    public func navigator(_ navigator: VisualNavigator, shouldNavigateToLink link: Link) -> Bool {
        rememberJump()
        return true
    }

    /// A tap: at the edge it pages, in the middle it shows the HUD - immediately. Only in
    /// a book with a glossary does the middle first ask the chapter whether a term was hit,
    /// and waits at most 250 ms for it: Readium's `evaluateJavaScript` otherwise waits
    /// until the spread reports "loaded", and a tap that never arrives is a
    /// hanging HUD.
    public func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        if let rejection = pointerGuard.check(point) {
            Diagnostics.step("Tap rejected: \(rejection.rawValue)", since: nil, area: "Reader")
            return
        }
        let size = self.navigator?.view.bounds.size ?? .zero
        let start = Date()
        Diagnostics.step(
            "Tap at \(Int(point.x)),\(Int(point.y)) of \(Int(size.width))×\(Int(size.height)) from \(pointerGuard.source)",
            since: nil, area: "Reader")
        // Terms are tappable across the whole width: a term at the start of a line used to turn
        // the page. With no term under the finger everything stays as before (edge pages,
        // middle shows the bars); the 250 ms wait
        // applies only in books with a glossary.
        // A tap in the edge quarter pages when "Always page at the edge" is on.
        let atMargin = point.x < size.width * 0.25 || point.x > size.width * 0.75
        guard glossary != nil, style.tap, !(style.edgeTurning && atMargin) else {
            Diagnostics.step("Tap: through immediately", since: nil, area: "Reader")
            tip?(point, size)
            return
        }
        let box = AnswerBox()
        Task { @MainActor [weak self] in
            box.value = .some(await self?.tappedTerm() ?? nil)
        }
        Task { @MainActor [weak self] in
            // In 10 ms steps: if the chapter answers quickly, the edge pages without
            // noticeable delay; at most 250 ms.
            for _ in 0..<25 where box.value == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let self else { return }
            if case .some(let entry?) = box.value {
                glossaryHits = entry
            } else {
                Diagnostics.step(
                    "Tap: through after \(Int(Date().timeIntervalSince(start) * 1000)) ms"
                        + (box.value == nil ? " (chapter did not answer)" : ""), since: nil,
                    area: "Reader")
                tip?(point, size)
            }
        }
    }

    /// The chapter's answer to the tap - `nil` while it is pending.
    @MainActor
    private final class AnswerBox {
        var value: Glossary.Item?? = nil
    }

    public func navigator(_ navigator: VisualNavigator, didPressKey event: KeyEvent) {
        pressedKey?(event.key)
    }

    public func navigator(
        _ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection
    ) -> Bool {
        true
    }
}

extension SpineCard {
    /// Two `href`s mean the same file - ignoring encoding, slash and fragment.
    static func equal(_ a: String, _ b: String) -> Bool {
        plain(a) == plain(b)
    }

    static func plain(_ href: String) -> String {
        var h = href.removingPercentEncoding ?? href
        if let hash = h.firstIndex(of: "#") { h = String(h[..<hash]) }
        while h.hasPrefix("/") { h.removeFirst() }
        return h
    }
}
