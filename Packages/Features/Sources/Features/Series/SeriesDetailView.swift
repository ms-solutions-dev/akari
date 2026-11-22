import AccountsKit
import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The series detail: cover, name, "46 read · Volume 47 · p. 63/205", the primary button,
/// then the volumes, as a grid up to 30 volumes and above that as a list with number,
/// state and a "Read" swipe. When opened, the list sits at the current volume once the
/// series is started; "To start" scrolls back. For an unread series volume 1 is the
/// current one, and scrolling there would only hide the header, so "To start" would not
/// exist.
///
/// On iPad (wide size class) long series appear in **two columns** of rows: 120 rows of
/// "Volume n - 190 pages" over 1,000 pt were a table without columns (rows, not grid). The
/// "Read" swipe belongs to the list; in the columns the context menu keeps the same entry.
/// At accessibility sizes it stays one list.
struct SeriesDetailView: View {
    /// "Reduce motion": then without animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let identifier: SeriesID

    @Environment(LibraryService.self) private var inventory
    @Environment(ReadCall.self) private var reader
    @Environment(Notices.self) private var notices
    @Environment(\.profile) private var profile
    @Environment(\.dynamicTypeSize) private var fontSize
    @Environment(\.horizontalSizeClass) private var width
    @State private var question = false

    var body: some View {
        if let series = inventory.series(identifier) {
            let state = inventory.seriesState(identifier)
            content(series)
                .titleOnScroll(Text(verbatim: series.name))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            SaveButton(target: .series(series.identifier))
                            CollectionMenu(target: .series(series.identifier))
                            if series.kind == .podcast, !profile.kind {
                                EpisodeBell(podcast: series.identifier)
                            }
                            if !state.completed {
                                Divider()
                                Button {
                                    question = true
                                } label: {
                                    Label(app: "series.allRead", systemImage: "checkmark.circle")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(Text(app: "reader.menu"))
                    }
                }
                .markAllReadQuestion(series, isPresented: $question)
        } else {
            EmptyState(glyph: "questionmark.square.dashed", title: Text(app: "error.notFound"))
        }
    }

    /// Three layouts: up to 30 volumes a grid in the scroll view, above that a list (only
    /// that has the "Read" swipe), and on iPad two columns of rows instead of the list; at
    /// accessibility sizes always the list.
    @ViewBuilder
    private func content(_ series: Series) -> some View {
        let volumes = inventory.volumes(identifier)
        let state = inventory.seriesState(identifier)
        let collectionKind = SeriesDetailView.collectionKind(
            volumes: volumes.count, large: fontSize.isAccessibilitySize, wide: width == .regular)
        let asList = collectionKind == .list
        let twoColumn = collectionKind == .columns
        ScrollViewReader { scroll in
            Group {
                if asList {
                    List {
                        Section {
                            SeriesHeader(series: series, state: state, volumes: volumes)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        Section {
                            ForEach(volumes) { volume in
                                VolumeRow(
                                    volume: volume, ongoing: volume.identifier == state.current?.identifier
                                )
                                .id(volume.identifier)
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            volumesHeader(volumes, state: state, scroll: scroll)
                        }
                    }
                    .listStyle(.plain)
                    .scrubHandle()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            SeriesHeader(series: series, state: state, volumes: volumes)
                            volumesHeader(volumes, state: state, scroll: scroll)
                            if twoColumn {
                                volumeColumns(volumes, state: state)
                            } else {
                                volumeGrid(volumes)
                            }
                        }
                        .padding()
                    }
                    .scrubHandle()
                }
            }
            .paper()
            .onAppear {
                // The volume list sits at the current volume, not at volume 1: whoever is
                // at 47 wants to see 47; whoever has read nothing sees the header.
                if asList || twoColumn, SeriesDetailView.scrollsToCurrent(state),
                    let current = state.current
                {
                    scroll.scrollTo(current.identifier, anchor: .top)
                }
            }
        }
    }

    /// The three layouts of the volume list.
    enum CollectionKind {
        case raster, list, columns
    }

    /// Which layout the volumes get: up to 30 the grid; above that on iPad two columns,
    /// otherwise the list; at accessibility sizes always the list.
    static func collectionKind(volumes: Int, large: Bool, wide: Bool) -> CollectionKind {
        if large { return .list }
        if volumes <= 30 { return .raster }
        return wide ? .columns : .list
    }

    /// Whether the list scrolls to the current volume on opening: only if the series is
    /// started; for an unread one volume 1 is "current", and scrolling there hid the header.
    static func scrollsToCurrent(_ state: Shelf.SeriesState) -> Bool {
        state.current != nil && (state.read > 0 || state.state != nil)
    }

    /// The grid of volumes, up to 30.
    private func volumeGrid(_ volumes: [Title]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: TileMetrics.raster(width), maximum: TileMetrics.gridCap(width)),
                    spacing: 12, alignment: .top)
            ],
            alignment: .leading, spacing: 20
        ) {
            ForEach(volumes) { volume in
                TitleTile(
                    title: volume, width: TileMetrics.raster(width),
                    secondaryLine: VolumeRow.secondaryLine(
                        volume, state: inventory.readingState(volume.identifier)),
                    inBookSeries: true
                )
                .id(volume.identifier)
            }
        }
    }

    /// Two columns of volume rows, on iPad from 31 volumes; each row with a hairline
    /// below, like the rows on Start.
    private func volumeColumns(_ volumes: [Title], state: Shelf.SeriesState) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 32), GridItem(.flexible())], alignment: .leading,
            spacing: 0
        ) {
            ForEach(volumes) { volume in
                VStack(spacing: 0) {
                    VolumeRow(volume: volume, ongoing: volume.identifier == state.current?.identifier)
                        .padding(.vertical, 6)
                    Hairline()
                }
                .id(volume.identifier)
            }
        }
    }

    /// "3 volumes - To start - ..." above the volumes.
    @ViewBuilder
    private func volumesHeader(
        _ volumes: [Title], state: Shelf.SeriesState, scroll: ScrollViewProxy
    ) -> some View {
        let kind = volumes.first?.kind
        HStack {
            Text(
                verbatim: Phrase.from(Formats.lookupKey("series.volumes.counter", kind: kind), volumes.count)
            )
            .font(Typography.name(.subheadline))
            .foregroundStyle(ColorTheme.muted.color)
            Spacer()
            if let first = volumes.first, state.current?.identifier != first.identifier {
                Button {
                    withAnimation(Motion.soft(reduceMotion)) {
                        scroll.scrollTo(first.identifier, anchor: .top)
                    }
                } label: {
                    Text(app: "series.toStart")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
            // Long series: a jump to a number, one every ten volumes (Bokraisik Branbros has 111).
            // "Mark all read" now lives in the bar's menu.
            if volumes.count > 30 {
                Menu {
                    ForEach(Array(stride(from: 0, to: volumes.count, by: 10)), id: \.self) { i in
                        let volume = volumes[i]
                        Button {
                            withAnimation(Motion.soft(reduceMotion)) {
                                scroll.scrollTo(volume.identifier, anchor: .top)
                            }
                        } label: {
                            Text(
                                verbatim: volume.series?.volume.map { Formats.volume($0, kind: volume.kind) }
                                    ?? Display(volume, inBookSeries: true).name)
                        }
                    }
                } label: {
                    Label(
                        appKey: Formats.lookupKey("series.jumpTo", kind: kind), systemImage: "number"
                    )
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
                .frame(minHeight: TapTarget.atLeast)
            }
        }
        .textCase(nil)
    }
}

/// The header: cover, name, authors, the state as sentence and bar, the primary button, the
/// summary (only if there is one) and the reading-direction note. Button and chips go as
/// actions into the `DetailHeader`, which places them in the text column on iPad.
struct SeriesHeader: View {

    let series: Series
    let state: Shelf.SeriesState
    let volumes: [Title]

    @Environment(ReadCall.self) private var reader
    @Environment(LibraryService.self) private var inventory
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.theme) private var theme
    @State private var keepUntil = false
    /// The color of the cover in the room.
    @State private var glow: AdaptiveColor?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader {
                Cover(series, width: TileMetrics.large(width)) { image in
                    glow = CoverColor.glow(from: image) ?? theme.accent
                }
                .tiltable()
                // The detail is the target of the zoom; its cover must not be a source at the same time.
                .environment(\.zoomSpace, nil)
                .background {
                    // The cover's light, breathing, behind the cover and fading out over
                    // the header line into the paper.
                    Glow(glow)
                        .frame(width: TileMetrics.large(width) * 3.2, height: TileMetrics.large(width) * 2.8)
                }
            } text: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: series.name)
                        .font(Typography.title(.title2))
                        .foregroundStyle(ColorTheme.typography.color)
                    if !series.authors.isEmpty {
                        AuthorLinks(names: series.authors, illustrators: series.illustrators)
                    }
                    if let rating = series.rating {
                        Stars(rating: rating)
                    }
                    let gaps = inventory.gaps(series.identifier)
                    Text(verbatim: SeriesHeader.statusLine(state, series: series, gaps: gaps))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(ColorTheme.muted.color)
                    if state.read > 0 {
                        ProgressBar(fraction: state.fraction)
                    }
                    if let line = gaps.flatMap(Formats.gaps) {
                        Text(verbatim: line)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(ColorTheme.muted.color)
                    }
                    if series.readingDirection == .rightToLeft {
                        Label(app: "series.rtl", systemImage: "arrow.left")
                            .font(.caption)
                            .foregroundStyle(ColorTheme.muted.color)
                    }
                }
            } actions: {
                if let target = state.current ?? volumes.first {
                    Button {
                        reader.open(target)
                    } label: {
                        Text(verbatim: SeriesHeader.button(state, kind: series.kind))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    .detailButton()
                }
                ChipRow {
                    SaveChip(target: .series(series.identifier))
                    if inventory.shelf.capabilities[series.identifier.source]?.contains(.keep) == true {
                        Button {
                            keepUntil = true
                        } label: {
                            Chip(
                                Text(appKey: Formats.lookupKey("keep.until", kind: series.kind)),
                                glyph: "arrow.down.circle", active: false)
                        }
                        .buttonStyle(.plain)
                    }
                    CollectionChip(target: .series(series.identifier))
                }
                .sheet(isPresented: $keepUntil) {
                    KeepUntilView(series: series)
                        .environment(inventory)
                }
            }
            if let text = series.summary {
                Summary(text: text)
            }
        }
    }

    /// "Text: Gihousglo Flanplias - Art: Siari Spaisla", otherwise just the names.
    static func authorRow(_ series: Series) -> String {
        guard !series.illustrators.isEmpty else { return series.authors.joined(separator: ", ") }
        return Phrase.from("series.text", series.authors.joined(separator: ", ")) + " · "
            + Phrase.from("series.drawing", series.illustrators.joined(separator: ", "))
    }

    /// "46 read - Volume 47 - p. 63/205 - 9 of 18 volumes - completed", only the parts that
    /// exist. The length of the series comes from the server, not the shelf: "All 9 read"
    /// would be wrong for 18 volumes. With `SeriesGaps` its checked length applies, since
    /// "6 of 9 volumes" beside "Volumes 1-5 missing" at volume 10 would contradict itself on
    /// one screen; without numbered volumes the server's length stays.
    static func statusLine(
        _ state: Shelf.SeriesState, series: Series? = nil, gaps: SeriesGaps? = nil
    )
        -> String
    {
        var share: [String] = []
        let kind = series?.kind ?? state.current?.kind
        if state.read > 0 { share.append(Phrase.from("series.read.counter", state.read)) }
        if let current = state.current, let number = current.series?.volume {
            share.append(Formats.volume(number, kind: current.kind))
        }
        if let s = state.state { share.append(Formats.short(s)) }
        let length = gaps.map(\.total) ?? series?.total
        if let total = length, total > state.total {
            share.append(Phrase.from(Formats.lookupKey("series.ofTotal", kind: kind), state.total, total))
        } else if state.read == 0 {
            // Without anything read the header carries the number of volumes; otherwise the
            // screen would have nine volumes and no line saying so.
            share.append(Phrase.from(Formats.lookupKey("series.volumes.counter", kind: kind), state.total))
        }
        if let status = series?.status { share.append(Phrase.from(status.lookupKey)) }
        return share.joined(separator: " · ")
    }

    /// "Continue at volume 47", "Read", "Read again".
    static func button(_ state: Shelf.SeriesState, kind: Kind) -> String {
        if state.completed { return Phrase.from(kind.isAudible ? "series.listenAgain" : "series.again") }
        if let current = state.current, let number = current.series?.volume,
            state.read > 0 || state.state != nil
        {
            return Phrase.from(
                Formats.lookupKey(
                    kind.isAudible ? "series.continueListeningAt" : "series.continueReadingAt", kind: kind),
                Formats.volumeNumber(number))
        }
        return Phrase.from(kind.readingKey)
    }
}

/// A row of the volume list: number in a box, name, state; swipe left for "Read".
struct VolumeRow: View {

    let volume: Title
    let ongoing: Bool

    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices

    var body: some View {
        let state = inventory.readingState(volume.identifier)
        NavigationLink(value: Target.title(volume.identifier)) {
            Row(
                index: volume.series?.volume.map(Formats.volumeNumber) ?? "–",
                name: Text(verbatim: Display(volume, inBookSeries: true).name),
                secondaryLine: VolumeRow.secondaryLine(volume, state: state),
                badge: inventory.shelf.keep.contains(volume.identifier)
                    ? Text(verbatim: Phrase.from("title.keep").uppercased()) : nil,
                ongoing: ongoing)
        }
        .buttonStyle(.plain)
        .titleMenu(volume)
        .swipeActions(edge: .trailing) {
            if state?.completed != true {
                Button {
                    notices.tryRun {
                        try await inventory.set(.read, for: volume.identifier)
                        Haptics.success()
                    }
                } label: {
                    Label(appKey: volume.kind.isReadKey, systemImage: "checkmark")
                }
                // Swipe area with white text: always the light signal value; the dark
                // one (pastel) would have too little contrast behind white.
                .tint(AdaptiveColor(ColorTheme.ok.light).color)
            }
        }
    }

    /// "p. 63/205", "Read", otherwise the size.
    static func secondaryLine(_ volume: Title, state: ReadingState?) -> Text? {
        if let state {
            if state.completed { return Text(appKey: volume.kind.isReadKey) }
            if state.started { return Text(verbatim: Formats.short(state)) }
        }
        return Formats.scope(volume.scope).map { Text(verbatim: $0) }
    }
}
