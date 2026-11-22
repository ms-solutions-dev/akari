import AccountsKit
import DesignSystem
import Library
import NetworkLocation
import OfflineStore
import PerformanceDiagnostics
import SourcesKit
import SourcesKitMocks
import SwiftUI

/// The start page: "What now?" within two seconds, offline.
///
/// From top to bottom: the brand mark in title size in the system bar (left, without
/// glass) and the account circle on the right, one row with no air above, the same
/// circle as in Library and Search; banners only when needed; Continue reading and
/// **Continue listening** kept apart (otherwise read and heard items mix), but **one
/// hero**: only the most recent reading across both gets the large card with the
/// page's only colored button, and the other row appears as plain rows; below that Up
/// next, New on the shelf, Saved (the top entry of the saved list first). Everything on
/// paper, so the ground must not change when moving into a detail. Empty rows vanish; no
/// genre, no greeting, no statistics. For a fresh account the page is one sentence and a
/// button into the library.
struct StartView: View {

    @Environment(AccountRegistry.self) private var accounts
    @Environment(LibraryService.self) private var inventory
    @Environment(ReadCall.self) private var reader
    @Environment(StockService.self) private var stock
    @Environment(\.imageTransport) private var transport
    @Environment(\.dynamicTypeSize) private var fontSize
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.importFile) private var importFile
    @AppStorage(StartRow.lookupKey) private var bottom = StartRow.new.rawValue
    @Binding var area: Area
    @State private var probeRan = false
    @State private var path = NavigationPath()
    @Environment(\.lightHeld) private var lightOutside
    /// The real width of the page: the size class alone also applies to iPad portrait
    /// and Split View, where two columns would be too narrow.
    @State private var pageWidth: CGFloat = 0

    /// Two columns only on iPad in landscape (from 1,000 pt), not at accessibility font sizes.
    private var twoColumn: Bool {
        width == .regular && pageWidth >= 1_000 && !fontSize.isAccessibilitySize
            && !inventory.shelf.continueReading.isEmpty
    }

    /// Light and tilt of the hero rest while it is not visible or while scrolling: under
    /// a detail on the stack, in another tab, and while scrolling. Whether SwiftUI stops a
    /// `TimelineView` there by itself is not guaranteed, and while scrolling every draw
    /// pass for the light costs frames.
    private var startLightPaused: Bool {
        lightOutside || !path.isEmpty || area != .start
    }

    var body: some View {
        let _ = Performance.build("Start")
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Brand mark and account circle in one row in the content: in the
                    // system bar the mark was squeezed to 31 pt (measured), here it is
                    // 44 like the circle; the circle carries its own glass so it looks
                    // like in Library and Search.
                    PageHeader {
                        BrandHeader()
                    } trailing: {
                        AccountCircle().glassCircle()
                    }
                    DisruptionBanner()
                    StatusBanner()
                    if twoColumn {
                        // iPad landscape: hero and started items on the left, the rows
                        // on the right; the width used to be half empty. The inner
                        // margins (16 pt each) plus 4 pt give the 36 pt of the mockup.
                        HStack(alignment: .top, spacing: 4) {
                            VStack(alignment: .leading, spacing: 28) { content }
                                .frame(maxWidth: 560, alignment: .leading)
                                .layoutPriority(1)
                            VStack(alignment: .leading, spacing: 28) { lowerPart }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // The scrolling rows draw without clipping: in the column,
                                // scrolled tiles would otherwise run over the left side. Clip
                                // only at the sides; shadow and glow above and below stay.
                                .mask(Rectangle().padding(.vertical, -60))
                        }
                    } else {
                        content
                        lowerPart
                    }
                }
                .padding(.vertical, 8)
            }
            // On the content, not the stack: the detail lying above should glow.
            .modifier(ScrollIdle(paused: startLightPaused))
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                pageWidth = $0
            }
            .paper()
            .refreshable { await inventory.refresh() }
            // No bar on Start: the brand mark takes its place; the tab is still called
            // Start, and whatever opens from here has its bar again.
            .navigationTitle(Text(app: "tab.start"))
            .withoutBar()
            .targets()
            .onChange(of: inventory.shelf.empty, initial: true) {
                // `AKARI_PROBE=serie|titel` opens the first detail right away for a
                // screenshot, otherwise the simulator could only get there by tapping.
                // The reader probes also run when the path was restored, otherwise the
                // simulator opens the book only every third time.
                let probe =
                    DisruptionProbe.present?.opens
                    ?? ProcessInfo.processInfo.environment["AKARI_PROBE"]
                    // `AKARI_ZEIGEN=holmes|holmes-buch`: the Sherlock Holmes series page / the
                    // first Holmes volume in the reader, for screenshots.
                    ?? ProcessInfo.processInfo.environment["AKARI_ZEIGEN"]
                let opensReader = [
                    "buch", "geraet", "lesen", "hoerbuch", "hoerbuch-behalten", "holmes-buch",
                ].contains(
                    probe ?? "")
                guard !inventory.shelf.empty, path.isEmpty || opensReader, !probeRan else { return }
                probeRan = true
                switch probe {
                case "serie": inventory.shelf.allSeries.first.map { push(Target.series($0.identifier)) }
                case "reihenluecken":
                    // The series with the fewest gaps: Sherlock Holmes (3), not Pepper&Carrot (35).
                    inventory.shelf.allSeries.compactMap { (s: Series) -> (Series, Int)? in
                        inventory.gaps(s.identifier).flatMap { (g: SeriesGaps) -> (Series, Int)? in
                            g.complete ? nil : (s, g.count)
                        }
                    }
                    .min { $0.1 < $1.1 }.map { push(Target.series($0.0.identifier)) }
                case "autor":
                    // The author page of the first book, for a screenshot with Wikipedia.
                    inventory.shelf.allTitles.first(where: { (t: Title) -> Bool in t.kind == Kind.book })?
                        .authors.first.map {
                            push(Target.author($0))
                        }
                case "rollen":
                    // The longest series; the scroll handle (DesignSystem) then scrolls it itself.
                    inventory.shelf.allSeries.max { $0.volumeCount < $1.volumeCount }.map {
                        push(Target.series($0.identifier))
                    }
                case "titel":
                    inventory.shelf.continueReading.first.map { push(Target.title($0.title.identifier)) }
                case "viele":
                    // The longest series, without the probe's scrolling `rollen`, for the
                    // two-column volume list on iPad (with `AKARI_VIELE=1`).
                    inventory.shelf.allSeries.max { $0.volumeCount < $1.volumeCount }.map {
                        push(Target.series($0.identifier))
                    }
                case "holmes":
                    inventory.shelf.allSeries.first { $0.name.contains("Sherlock") }.map {
                        push(Target.series($0.identifier))
                    }
                case "holmes-buch":
                    inventory.shelf.allTitles.first { $0.name.contains("Adventures of Sherlock") }.map {
                        reader.open($0)
                    }
                case "gemerkt": push(Target.saved)
                case "liegengeblieben": bottom = StartRow.stalled.rawValue
                case "lesen":
                    // The comic reader for a screenshot: the started manga, otherwise
                    // the first on the shelf.
                    let manga = StartView.sampleManga(inventory.shelf)
                    manga.map { reader.open($0) }
                case "buch":
                    let book =
                        inventory.shelf.continueReading.map(\.title).first { $0.kind == .book }
                        ?? inventory.shelf.allTitles.first { $0.kind == .book }
                    // One second later: while the path is being restored, SwiftUI
                    // swallows the full-screen presentation.
                    if let book {
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            reader.open(book)
                        }
                    }
                case "import":
                    // The import for a screenshot: the mock EPUB as a file from the device.
                    // AKARI_IMPORT_DATEI: a real EPUB from the computer instead of the mock
                    // (the simulator reads the Mac file tree), for bugs that only real
                    // books show.
                    let file = FileManager.default.temporaryDirectory.appending(path: "Die Probe.epub")
                    if let real = ProcessInfo.processInfo.environment["AKARI_IMPORT_DATEI"] {
                        try? FileManager.default.removeItem(at: file)
                        try? FileManager.default.copyItem(at: URL(filePath: real), to: file)
                    } else {
                        try? MockBook.epub(glossary: true).write(to: file)
                    }
                    importFile([file])
                case "geraet":
                    // The first title from the device in the reader, after an import run.
                    inventory.shelf.allTitles.first { $0.identifier.source.provider == .device }.map {
                        reader.open($0)
                    }
                case "teilen":
                    // The share sheet for a screenshot: the first book.
                    inventory.shelf.allTitles.first { $0.kind == .book }.map { reader.titleToShare = $0 }
                case "hoerbuch", "mini":
                    let audiobook =
                        inventory.shelf.continueReading.map(\.title).first { $0.kind == .audiobook }
                        ?? inventory.shelf.allTitles.first { $0.kind == .audiobook }
                    audiobook.map { reader.open($0) }
                    // `mini`: the sheet closes after four seconds, the mini player
                    // stays, for its position above the bar, under the pill on iPad.
                    if probe == "mini" {
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            reader.title = nil
                        }
                    }
                case "hoerbuch-behalten":
                    // The title sheet of the shortest audiobook, and after one and a half
                    // seconds keeping starts by itself: ring, then "Loaded", without a tap
                    // in the simulator. With mocks that is 600 WAV minutes, around 580 MB
                    // under the simulator's Application Support. If it is already there
                    // (second run), the player opens instead, with the tracks from the
                    // device; the log says "from device".
                    let audiobooks = inventory.shelf.allTitles.filter { $0.kind == .audiobook }
                    guard
                        let title = audiobooks.min(by: {
                            ($0.size ?? .max) < ($1.size ?? .max)
                        }) ?? audiobooks.first,
                        let source = inventory.source(title.identifier.source)
                    else { break }
                    push(Target.title(title.identifier))
                    let transport = transport(title.identifier.source.provider)
                    let done = stock.entry(title.identifier)?.done == true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if done {
                            reader.open(title)
                        } else {
                            stock.requestKeep(title, source: source, transport: transport)
                        }
                    }
                default: break
                }
            }
            // "To the series" from the end-of-volume sheet: the reader closes, Start takes
            // the target onto its stack, one stack, one path, also from the library.
            .onChange(of: reader.jump) { _, target in
                guard let target else { return }
                reader.jump = nil
                area = .start
                push(target)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let shelf = inventory.shelf
        let all = shelf.continueReading
        let readings = all.filter { !$0.title.kind.isAudible }
        let listenings = all.filter { $0.title.kind.isAudible }
        if accounts.configured && all.isEmpty && !inventory.storeRead {
            // Persistence is still reading: calm paper, not "nothing started yet"; until
            // then the shelf holds only the downloads, without reading states.
            // Persistence is still reading (a fraction of a second): calm paper instead of the empty state.
            Color.clear.frame(height: 1)
        } else if !accounts.configured && shelf.empty {
            // Nothing set up yet: the same empty shelf as in the library.
            EmptyShelf()
        } else if shelf.empty && inventory.refreshing {
            EmptyState(glyph: "books.vertical", title: Text(app: "start.fetches.title")) {
                ProgressView()
            }
        } else if all.isEmpty {
            EmptyState(
                worm: Text(app: shelf.empty ? "start.empty.title" : "start.nothingStarted.title"),
                text: Text(app: shelf.empty ? "start.empty.text" : "start.nothingStarted.text"),
                pose: .read
            ) {
                if !shelf.empty {
                    Button {
                        area = .library
                    } label: {
                        Text(app: "start.toLibrary")
                    }
                    .buttonStyle(.primary)
                }
            }
        } else {
            // The hero is the most recent reading across both rows; the other row
            // comes without a card, and the hero's row comes first.
            let heroAudible = all[0].title.kind.isAudible
            if heroAudible {
                if !listenings.isEmpty { proceed(listenings, listen: true, withHero: true) }
                if !readings.isEmpty { proceed(readings, listen: false, withHero: false) }
            } else {
                if !readings.isEmpty { proceed(readings, listen: false, withHero: true) }
                if !listenings.isEmpty { proceed(listenings, listen: true, withHero: false) }
            }
        }
    }

    /// What follows Continue reading: Up next, New or the chosen row, Saved. On iPad the
    /// right column, on iPhone below.
    @ViewBuilder
    private var lowerPart: some View {
        let shelf = inventory.shelf
        if !shelf.empty {
            let next = shelf.asNext
            if !next.isEmpty {
                line(Text(app: "start.next"), all: nil) {
                    ForEach(next) { n in
                        entry(.title(n.title), secondaryLine: Text(verbatim: StartView.nextRow(n)))
                    }
                }
            }
            // What is at the bottom is the user's choice: New on the shelf, their own
            // collections, or nothing.
            switch StartRow(rawValue: bottom) ?? .new {
            case .collections: CollectionRow(kind: nil)
            case .from: EmptyView()
            case .new: newOnShelf(shelf)
            case .stalled: stalled(shelf)
            }
            let saved = shelf.savedEntries
            if !saved.isEmpty {
                line(Text(app: "start.saved"), all: .saved) {
                    ForEach(saved.prefix(10)) { e in
                        entry(e, secondaryLine: nil)
                    }
                }
            }
            onDevice
        }
    }

    @ViewBuilder
    private func newOnShelf(_ shelf: Shelf) -> some View {
        let new = shelf.newOnShelf
        if !new.isEmpty {
            line(Text(app: "start.new"), all: new.count > 10 ? .new : nil) {
                ForEach(new.prefix(10)) { n in
                    switch n {
                    case .series(let series, let volumes):
                        entry(
                            .series(series),
                            secondaryLine: Text(
                                verbatim: Phrase.from(
                                    Formats.lookupKey("new.series", kind: series.kind), volumes.count))
                        )
                    case .title(let title):
                        entry(
                            .title(title), secondaryLine: StartView.newRow(title).map { Text(verbatim: $0) }
                        )
                    }
                }
            }
        }
    }

    /// Stalled: started but no longer visible under Continue reading; a row at the
    /// bottom when the user chooses it; the visibility rule is computed by the shelf.
    @ViewBuilder
    private func stalled(_ shelf: Shelf) -> some View {
        let stalledTitles = shelf.stalled
        if !stalledTitles.isEmpty {
            line(Text(app: "statistics.stalled"), all: stalledTitles.count > 6 ? .stalled : nil) {
                ForEach(stalledTitles.prefix(6)) { l in
                    entry(.title(l.title), secondaryLine: Text(verbatim: StatisticsView.stalledRow(l)))
                }
            }
        }
    }

    /// Continue reading or Continue listening: the same form, separate rows. With hero:
    /// the card, below it up to three rows; without: up to three rows. Rows, not tiles:
    /// they fill the width whether two or three, and carry the state in fixed digits.
    @ViewBuilder
    private func proceed(_ readings: [Shelf.Reading], listen: Bool, withHero: Bool) -> some View {
        let limit = withHero ? 4 : 3
        VStack(alignment: .leading, spacing: 12) {
            RowHeader(
                title: Text(app: listen ? "start.continueListening" : "start.continueReading"),
                all: readings.count > limit ? (listen ? .continueListening : .continueReading) : nil)
            if withHero {
                ContinueReadingCard(reading: readings[0])
                    .padding(.horizontal)
            }
            let further = Array((withHero ? readings.dropFirst() : readings[...]).prefix(3))
            if !further.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(further.enumerated()), id: \.element.id) { i, l in
                        EntryRow(
                            entry: .title(l.title), secondaryLine: Text(verbatim: StartView.statusLine(l)),
                            withKind: true, coverWidth: TileMetrics.rowLarge
                        )
                        // Six points of air: at AX1 the text fills the cover height, and
                        // without margin the badge stuck to the hairline.
                        .padding(.vertical, 6)
                        if i < further.count - 1 { Hairline() }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// What is on the device: running downloads first, then the newest; "All" leads to the
    /// page with usage and a grid per kind.
    @ViewBuilder
    private var onDevice: some View {
        let list = DeviceView.list(stock: stock, inventory: inventory)
        if !list.isEmpty {
            line(
                Text("\(Text(app: "storage.keep")) · \(Formats.bytes(stock.sum))"),
                all: .device
            ) {
                ForEach(list.prefix(10)) { e in
                    entry(.title(e.title), secondaryLine: DeviceView.secondaryLine(e.keep))
                }
            }
        }
    }

    /// A row with a header; at large font sizes as a list instead of a strip.
    @ViewBuilder
    private func line<Content: View>(
        _ title: Text, all: Target?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RowHeader(title: title, all: all)
            if fontSize.isAccessibilitySize {
                VStack(spacing: 12) { content() }.padding(.horizontal)
            } else {
                TileRow { content() }
            }
        }
    }

    @ViewBuilder
    private func entry(_ entry: Shelf.Item, secondaryLine: Text?) -> some View {
        if fontSize.isAccessibilitySize {
            EntryRow(entry: entry, secondaryLine: secondaryLine, withKind: true)
        } else {
            switch entry {
            case .series(let s):
                SeriesTile(
                    series: s, width: TileMetrics.line(width), secondaryLine: secondaryLine, withKind: true)
            case .title(let t):
                TitleTile(
                    title: t, width: TileMetrics.line(width), secondaryLine: secondaryLine, withKind: true)
            }
        }
    }

    /// A target onto the stack, on the next turn, not in the current pass.
    ///
    /// On iPad the bar of a detail showed two forms: sometimes Back and the ellipsis
    /// **in** the tab row next to the pill, sometimes in a row of their own below.
    /// Reproduced with the probe `titel`: if UIKit rebuilds the tab bar while a detail is
    /// on the stack, it merges the detail's bar with the tab row. That is exactly what
    /// happens at launch: with the shelf filled, the genre sections arrive in the sidebar,
    /// and a push **in the same pass** (deep link, probe, jump from the reader) landed
    /// sometimes before and sometimes after the rebuild; of seven synchronous runs, four
    /// merged and three got their own row. A push on the next turn comes after the
    /// rebuild and gets its own row like every tap, seven of seven runs. That is why all
    /// pushes that do not come from a tap go through here. What remains: if the size
    /// class changes back and forth (Split View), UIKit rebuilds the tabs and an open
    /// detail then shows the merged form; the detail's header relies on no fixed
    /// spacing, the content simply moves up 70 pt.
    private func push(_ target: Target) {
        Task { @MainActor in path.append(target) }
    }

    /// The manga for the probe `lesen`: the started one, otherwise the first on the
    /// shelf; `AKARI_LESEN=<name part>` picks a specific one, for measurements on the webtoon.
    static func sampleManga(_ shelf: Shelf) -> Title? {
        let started = shelf.continueReading.map(\.title).filter { $0.kind == .manga }
        if let searched = ProcessInfo.processInfo.environment["AKARI_LESEN"]?.lowercased() {
            let hit = started.first { title in
                let name = title.series?.name ?? title.name
                return name.lowercased().contains(searched)
            }
            if let hit { return hit }
        }
        return started.first ?? shelf.allTitles.first { $0.kind == .manga }
    }

    /// "Volume 48" or "New, Volume 48"; without a number the series name.
    static func nextRow(_ n: Shelf.Next) -> String {
        let volume =
            n.title.series?.volume.map { Formats.volume($0, kind: n.title.kind) } ?? n.title.series?.name
            ?? ""
        return n.new ? Phrase.from("new.prefix", volume) : volume
    }

    /// "Volume 47, p. 63/205" for manga, otherwise just the state.
    static func statusLine(_ l: Shelf.Reading) -> String {
        Display(l.title, inBookSeries: false).secondaryLine(Formats.short(l.state), author: nil)
            ?? Formats.short(l.state)
    }

    /// "yesterday", the date only: the badge in front carries the kind, and "AUDIOBOOK,
    /// Audiobook, 6 days ago" would say it twice.
    static func newRow(_ title: Title) -> String? {
        title.added.map(Formats.her)
    }
}

/// The one large element: cover on the left, beside it kind, name, series, bar with
/// number and the button; text beside the cover, never on it. Everything at the leading
/// edge: the outer stack aligns left, otherwise at accessibility sizes it would center
/// the 520 pt text on iPad off by 240 pt, and the button keeps the same cap there.
struct ContinueReadingCard: View {

    let reading: Shelf.Reading

    @Environment(ReadCall.self) private var reader
    @Environment(\.dynamicTypeSize) private var fontSize
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.theme) private var theme
    /// The color the cover throws into the room; `nil` until the image is there, or for
    /// gray covers, in which case the accent glows, muted.
    @State private var glow: AdaptiveColor?

    var body: some View {
        // From accessibility sizes on, no title fits beside the cover; the cover then
        // sits above the text and the button takes the full width.
        let large = fontSize.isAccessibilitySize
        let arrangement =
            large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        VStack(alignment: .leading, spacing: 12) {
            arrangement {
                // Cover and text are one link (half the card used to be dead); the button
                // below stays its own target. On iPad the text does not run beyond
                // 1,200 pt.
                NavigationLink(value: Target.title(reading.title.identifier)) {
                    arrangement {
                        Cover(reading.title, width: TileMetrics.large(width)) { image in
                            glow = CoverColor.glow(from: image) ?? theme.accent
                        }
                        // Books as objects: the cover tilts along.
                        .tiltable()
                        text
                            .frame(
                                maxWidth: width == .regular ? TileMetrics.detailColumn : nil,
                                alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: Display(reading.title, inBookSeries: false).name))
                .titleMenu(reading.title)
                if !large { Spacer(minLength: 0) }
            }
            HStack {
                if !large { Spacer().frame(width: TileMetrics.large(width) + 16) }
                button
                Spacer(minLength: 0)
            }
            // The card's bottom edge: without it, cover and text do not read as one
            // card.
            Hairline()
        }
        .background(alignment: .topLeading) {
            // The glow behind the cover, breathing. It is larger than the card and fades
            // into the paper; while scrolling it stays half behind (parallax 0.5x), so the
            // hero visibly lies above the light.
            let mass = TileMetrics.large(width)
            Glow(glow)
                .frame(width: mass * 3, height: mass * 2.6)
                .offset(x: -mass * 0.9, y: -mass * 0.6)
                .scrollTransition(axis: .vertical) { content, phase in
                    content.offset(y: phase.value * mass * 0.25)
                }
        }
    }

    private var text: some View {
        let title = reading.title
        let display = Display(title, inBookSeries: false)
        return VStack(alignment: .leading, spacing: 8) {
            Badge(Text(appKey: title.kind.lookupKey))
            Text(verbatim: display.name)
                .font(Typography.title(.title3))
                .foregroundStyle(ColorTheme.typography.color)
                .lineLimit(3)
            if let series = title.series {
                // For manga the series is already on top, so only "Volume 1" here.
                Text(
                    verbatim: display.volume ?? series.volume.map {
                        series.name + " · " + Formats.volume($0, kind: title.kind)
                    }
                        ?? series.name
                )
                .font(.subheadline)
                .foregroundStyle(ColorTheme.muted.color)
                .lineLimit(2)
            }
            ProgressBar(fraction: reading.state.fraction, text: Text(verbatim: Formats.long(reading.state)))
        }
    }

    private var button: some View {
        Button {
            reader.open(reading.title)
        } label: {
            Text(appKey: reading.title.kind.continueKey)
                .frame(maxWidth: fontSize.isAccessibilitySize ? .infinity : nil, minHeight: 28)
        }
        .buttonStyle(.primary)
        .frame(
            maxWidth: fontSize.isAccessibilitySize && width == .regular
                ? TileMetrics.detailColumn : nil,
            alignment: .leading)
    }
}

/// The banner for when the shelf comes from persistence and no server answered:
/// "As of yesterday 21:14". The network watcher turns that into "Offline".
///
/// Also: "Slow connection, ~0.3 Mbit/s" from the ``NetworkMeter`` (the tunnel where a
/// page takes 19 s), and after catching up, for a few seconds "2 reading states
/// delivered", so that what was read offline visibly arrived and the number does not
/// just disappear.
struct StatusBanner: View {

    @Environment(LibraryService.self) private var inventory
    @Environment(NetworkWatch.self) private var network
    @Environment(NetworkMeter.self) private var metering
    @Environment(\.accessibilityReduceMotion) private var calm
    /// Which "delivered" has already faded; the banner shows only a newer one.
    @State private var hiddenAt: Date?

    /// How long "delivered" stays.
    static let deferredDuration: Duration = .seconds(6)

    var body: some View {
        // Offline: "Offline, as of yesterday 21:14, only available items readable"; the
        // network watcher knows before a server fails to answer.
        if network.reported, !network.route.usable, let state = inventory.shelf.state {
            // Plus what was read offline and is waiting, so nobody thinks it is gone.
            let text = Phrase.from(
                "start.offline", state.formatted(.relative(presentation: .named)),
                state.formatted(date: .omitted, time: .shortened))
            let waitSuffix =
                inventory.pending > 0 ? " · " + Phrase.from("start.supply", inventory.pending) : ""
            Banner(.offline, level: .warning, text: Text(verbatim: text + waitSuffix))
        } else if inventory.fromCache, !inventory.failure.isEmpty, let state = inventory.shelf.state {
            Banner(
                .offline,
                text: Text(
                    verbatim: Phrase.from(
                        "start.state", state.formatted(.relative(presentation: .named)),
                        state.formatted(date: .omitted, time: .shortened)))
            ) {
                Button {
                    Task { await inventory.refresh() }
                } label: {
                    Text(app: "disruption.again")
                }
            }
        } else if let source = inventory.failure.keys.min(by: { $0.description < $1.description }) {
            // One source did not arrive while the others did; it used to be missing
            // silently (a large Grimmory library was gone and nothing said so).
            let name = Text(appKey: "account.kind." + source.provider.rawValue)
            let age = inventory.shelf.state(source).map {
                " · "
                    + Phrase.from(
                        "start.state", $0.formatted(.relative(presentation: .named)),
                        $0.formatted(date: .omitted, time: .shortened))
            }
            Banner(
                .offline,
                text: Text("\(name): \(Text(app: "start.catalogMissing"))\(Text(verbatim: age ?? ""))")
            ) {
                Button {
                    Task { await inventory.refresh() }
                } label: {
                    Text(app: "disruption.again")
                }
            }
        } else if let supplied = inventory.supplied, supplied.around != hiddenAt {
            Banner(.hint, text: Text(verbatim: Phrase.from("start.supplied", supplied.count)))
                .task(id: supplied.around) {
                    try? await Task.sleep(for: StatusBanner.deferredDuration)
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.soft(calm)) { hiddenAt = supplied.around }
                }
        } else if case .slow(let mbit) = metering.phase, !metering.hidden {
            let integer = mbit.formatted(.number.precision(.fractionLength(1)))
            let waitSuffix =
                inventory.pending > 0 ? " · " + Phrase.from("start.supply", inventory.pending) : ""
            Banner(
                .offline, level: .warning,
                text: Text(verbatim: Phrase.from("start.slow", integer) + waitSuffix)
            ) {
                Button {
                    withAnimation { metering.fadeOut() }
                } label: {
                    Text(app: "banner.hide")
                }
            }
        }
    }
}

/// The list behind "All" for Continue reading: rows with state, swipe left "Read".
struct ContinueReadingList: View {

    /// Only audiobooks ("Continue listening") or everything else.
    var listen = false

    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices

    var body: some View {
        List {
            ForEach(inventory.shelf.continueReading.filter { $0.title.kind.isAudible == listen }) { l in
                EntryRow(
                    entry: .title(l.title), secondaryLine: Text(verbatim: StartView.statusLine(l)),
                    withKind: true
                )
                .swipeActions(edge: .trailing) {
                    Button {
                        notices.tryRun {
                            try await inventory.set(.read, for: l.title.identifier)
                            Haptics.success()
                        }
                    } label: {
                        Label(appKey: l.title.kind.isReadKey, systemImage: "checkmark")
                    }
                    // Swipe surface with white text: always the light signal value; the
                    // dark one (pastel) would have too little contrast behind white.
                    .tint(AdaptiveColor(ColorTheme.ok.light).color)
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .paper()
        .navigationTitle(Text(app: listen ? "start.continueListening" : "start.continueReading"))
        .toolbarTitleDisplayMode(.inline)
    }
}

/// The list behind "All" for New on the shelf.
struct NewList: View {

    @Environment(LibraryService.self) private var inventory

    var body: some View {
        List {
            ForEach(inventory.shelf.newOnShelf) { n in
                Group {
                    switch n {
                    case .series(let series, let volumes):
                        EntryRow(
                            entry: .series(series),
                            secondaryLine: Text(
                                verbatim: Phrase.from(
                                    Formats.lookupKey("new.series", kind: series.kind), volumes.count)),
                            withKind: true)
                    case .title(let title):
                        EntryRow(
                            entry: .title(title),
                            secondaryLine: StartView.newRow(title).map { Text(verbatim: $0) },
                            withKind: true)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .paper()
        .navigationTitle(Text(app: "start.new"))
        .toolbarTitleDisplayMode(.inline)
    }
}

/// A hairline in the theme color, between rows and under the card.
struct Hairline: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Rectangle().fill(theme.hairline.color).frame(height: 1)
    }
}

/// What is at the bottom of Start: a setting in the account sheet (make New on the
/// shelf replaceable, with own shelves or hidden entirely); also Stalled, and the
/// default stays New on the shelf.
enum StartRow: String, CaseIterable, Identifiable {
    case new = "neu", collections = "sammlungen", stalled = "liegengeblieben", from = "aus"
    /// Storage key (UserDefaults): stays `start.unten`, although the catalog key of the label is `start.bottom`.
    static let lookupKey = "start.unten"
    var id: String { rawValue }
    var keyName: String { "start.bottom." + rawValue }
}

/// Light and tilt rest while scrolling, with their own state: when `scrolls` lived in
/// the start page, it recomputed completely at every start and end of scrolling.
private struct ScrollIdle: ViewModifier {
    let paused: Bool
    @State private var scrolls = false

    func body(content: Content) -> some View {
        content
            .environment(\.lightHeld, paused || scrolls)
            .onScrollPhaseChange { _, phase in
                if scrolls != phase.isScrolling { scrolls = phase.isScrolling }
            }
    }
}
