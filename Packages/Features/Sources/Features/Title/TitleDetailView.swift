import DesignSystem
import Library
import OfflineStore
import SourcesKit
import SwiftUI

/// The title detail: cover, name, author and series, the details in **one**
/// muted line, the status in the column, "Read" as the primary button, which never
/// changes its text, the chips, the summary, the community stars with
/// origin, and last the server. Three type sizes in the column, not five.
/// What the server did not say is missing; no row claims "0 pages".
struct TitleDetailView: View {

    let identifier: TitleID

    @Environment(LibraryService.self) private var inventory
    @Environment(ReadCall.self) private var reader
    @Environment(Notices.self) private var notices
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.theme) private var theme
    @Environment(StockService.self) private var stock
    @Environment(\.inBook) private var inBook
    @State private var deleteQuestion = false
    @State private var inBookPage: InBookSheet?
    /// The cover's color in the room; until then the accent, muted.
    @State private var glow: AdaptiveColor?

    var body: some View {
        Group {
            if let title = inventory.titleForDetail(identifier) {
                found(title)
            } else {
                EmptyState(glyph: "questionmark.square.dashed", title: Text(app: "error.notFound"))
            }
        }
        // Blurb and title the catalog does not carry come from the server on opening.
        .task(id: identifier) { await inventory.details(for: identifier) }
    }

    private func found(_ title: Title) -> some View {
        content(title)
            .navigationTitle(Text(verbatim: title.series?.name ?? title.name))
            .toolbarTitleDisplayMode(.inline)
            // The more menu with the context menu's content, visible and reachable
            // for VoiceOver; the long press on the cover stays.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        TitleMenuContent(title: title, inDetail: true, deleteQuestion: $deleteQuestion)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text(app: "reader.menu"))
                }
            }
            .titleDeleteQuestion(title, isPresented: $deleteQuestion)
    }

    private func content(_ title: Title) -> some View {
        let state = inventory.readingState(identifier)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if width == .regular {
                    DetailHeader(spacing: 20) {
                        // iPad: cover 240 on the left; the 120 pt header used to
                        // look lost.
                        Cover(title, width: 240) { image in
                            glow = CoverColor.glow(from: image) ?? theme.accent
                        }
                        .tiltable()
                        // The detail is the zoom's target, so its cover must not also be a source.
                        .environment(\.zoomSpace, nil)
                        .titleMenu(title)
                    } text: {
                        headerText(title, state, centered: false)
                    } actions: {
                        actions(title, state)
                    }
                } else {
                    // Compact: the cover large and centered on its light,
                    // everything below centered, then button and actions at full width.
                    VStack(spacing: 18) {
                        Cover(title, width: 168) { image in
                            glow = CoverColor.glow(from: image) ?? theme.accent
                        }
                        .tiltable()
                        // The detail is the zoom's target, so its cover must not also be a source.
                        .environment(\.zoomSpace, nil)
                        .titleMenu(title)
                        .padding(.top, 8)
                        headerText(title, state, centered: true)
                        VStack(spacing: 12) {
                            actions(title, state)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if let text = title.summary {
                    Summary(text: text)
                }
                if let rating = title.rating {
                    Stars(rating: rating)
                }
                // The origin is an operational display, not title information; last,
                // small, not in the column next to the cover.
                Text(
                    verbatim: identifier.source.provider == .device
                        ? Phrase.from("account.kind.geraet") : identifier.source.server
                )
                .font(.caption2)
                .foregroundStyle(ColorTheme.muted.color)
            }
            .padding()
            .background(alignment: width == .regular ? .topLeading : .top) {
                // The cover's light behind the header, breathing; on scrolling
                // it stays in place and the cover moves away above it. Its
                // center lies on the cover; since the edge fades out completely,
                // only that glows: centered when compact, by the cover on the left on iPad.
                if width == .regular {
                    Glow(glow)
                        .frame(width: 720, height: 600)
                        .offset(x: -224, y: -104)
                } else {
                    Glow(glow)
                        .frame(height: 460)
                        .padding(.horizontal, -60)
                        .offset(y: -80)
                }
            }
            // The other volumes of the series so the detail does not end in empty space,
            // and the way to the series right beside it.
            if let series = title.series {
                let other = inventory.volumes(series.identifier).filter { $0.identifier != identifier }
                if !other.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        RowHeader(title: Text(app: "title.bookSeries"), all: .series(series.identifier))
                        TileRow {
                            ForEach(other) { volume in
                                TitleTile(
                                    title: volume, width: TileMetrics.line(width),
                                    secondaryLine: VolumeRow.secondaryLine(
                                        volume, state: inventory.readingState(volume.identifier)),
                                    inBookSeries: true)
                            }
                        }
                    }
                    .padding(.bottom)
                }
            }
        }
        .paper()
    }

    /// Name, author, series, details, publisher and status: on the left next to the cover (iPad) or
    /// centered below it (iPhone).
    @ViewBuilder
    private func headerText(_ title: Title, _ state: ReadingState?, centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Badge(Text(appKey: title.kind.lookupKey))
            // For manga "Volume 1"; the file name stays invisible.
            Text(verbatim: Display(title, inBookSeries: true).name)
                .font(Typography.title(.title2))
                .foregroundStyle(ColorTheme.typography.color)
            if let subtitle = title.subtitle {
                Text(verbatim: subtitle)
                    .font(Typography.title(.subheadline, weight: .regular))
                    .foregroundStyle(ColorTheme.muted.color)
                    .lineLimit(2)
            }
            if !title.authors.isEmpty {
                AuthorLinks(names: title.authors)
            }
            if let series = title.series {
                NavigationLink(value: Target.series(series.identifier)) {
                    HStack(spacing: 4) {
                        Text(
                            verbatim: TitleDetailView.bookSeriesLink(
                                title, series: series,
                                total: inventory.series(series.identifier)?.total))
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.subheadline)
                }
            }
            let details = TitleDetailView.details(title)
            if !details.isEmpty {
                Text(verbatim: details.joined(separator: " · "))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
                    .lineLimit(2)
            }
            if let publisher = title.publisher, !publisher.isEmpty {
                NavigationLink(value: Target.publisher(publisher)) {
                    HStack(spacing: 4) {
                        Text(verbatim: publisher)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.footnote)
                }
            }
            if let state, state.started {
                ProgressBar(
                    fraction: state.fraction,
                    text: Text(
                        verbatim: Formats.long(state) + " · " + TitleDetailView.recently(state))
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            } else if let state, state.completed {
                Label {
                    Text(
                        verbatim: Phrase.from(title.kind.isReadKey) + " · "
                            + TitleDetailView.recently(state))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .font(.footnote)
                .foregroundStyle(ColorTheme.muted.color)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
    }

    /// The main button and the action row.
    @ViewBuilder
    private func actions(_ title: Title, _ state: ReadingState?) -> some View {
        // Started reads "Continue reading, page 3 of 227", otherwise "Read";
        // the button says what happens.
        Button {
            reader.open(title)
        } label: {
            if let state, state.started {
                VStack(spacing: 2) {
                    Text(appKey: title.kind.continueKey)
                    // The subline only when it says more than the bar above it:
                    // "Page 3 of 227", "10 h 30 min left", not "40 %" once more.
                    if let exact = TitleDetailView.exact(state) {
                        Text(verbatim: exact)
                            .font(.caption)
                            .opacity(0.85)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if let state, state.completed {
                Text(appKey: title.kind.againKey)
                    .frame(maxWidth: .infinity)
            } else {
                Text(appKey: title.kind.readingKey)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.primary)
        .detailButton()
        // The action row: Saved, Collection, Read, Keep: one chip style,
        // scrolling rather than wrapping: four chips do not fit side by side, and a
        // chip that splits "Saved" is none.
        ChipRow {
            SaveChip(target: .title(identifier))
            CollectionChip(target: .title(identifier))
            Menu {
                ReadingStatusSwitch(title: title, status: ReadStatus(state))
            } label: {
                Chip(
                    Text(appKey: title.kind.isReadKey), glyph: "checkmark.circle",
                    active: state?.completed == true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            KeepButton(title: title, chip: true)
            // "In the book" also without the reader, for kept books that were already opened.
            if let file = stock.files(identifier)?.first, let page = inBook?(identifier.description, file) {
                Button {
                    inBookPage = InBookSheet(viewMode: page)
                } label: {
                    Chip(Text(app: "book.inBook"), glyph: "person.text.rectangle", active: false)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $inBookPage) { $0.viewMode }
    }

    /// The link to the series: for manga only "Blawosfil Saga" (the number is in the
    /// heading), for books "Sherlock Holmes, volume 2 of 3" if the server knows the length.
    static func bookSeriesLink(_ title: Title, series: SeriesReference, total: Int? = nil) -> String {
        if title.kind == .manga, series.volume != nil { return series.name }
        return series.volume.map { series.name + " · " + Formats.volume($0, from: total, kind: title.kind) }
            ?? series.name
    }

    /// The subline of the continue-reading button: "Page 3 of 227", "10 h 30 min left";
    /// for bare percentages nothing, they are already in the bar.
    static func exact(_ state: ReadingState) -> String? {
        switch state.position {
        case .page, .second: Formats.long(state)
        case .position, .fraction: nil
        }
    }

    /// "last read yesterday", from the timestamp every server sends and
    /// nobody showed so far.
    static func recently(_ state: ReadingState) -> String {
        Phrase.from("title.recently", Formats.her(state.timestamp))
    }

    /// The parts of the details line: "205 pages", "EPUB", "1.2 MB", "Narrator:
    /// S. Voice", "German", "age 12+"; the view joins them with dots into one
    /// line; the publisher stands below as a link. Format and size are included, since for
    /// books it should be visible which format it is; audiobooks from Audiobookshelf only
    /// know theirs in the detail.
    static func details(_ title: Title) -> [String] {
        var rows: [String] = []
        if let scope = Formats.scope(title.scope) { rows.append(scope) }
        if let chapter = title.chapter { rows.append(Phrase.from("title.chapter", chapter)) }
        if let format = title.format { rows.append(format) }
        if let size = title.size, size > 0 { rows.append(Formats.bytes(size)) }
        if let released = title.released { rows.append(Formats.year(released)) }
        if !title.narrator.isEmpty {
            rows.append(Phrase.from("title.narrator", title.narrator.joined(separator: ", ")))
        }
        if let language = title.language, let name = Locale.current.localizedString(forLanguageCode: language)
        {
            rows.append(name.capitalized(with: .current))
        }
        if let age = title.ageRating { rows.append(Phrase.from("title.ageRating", age)) }
        return rows
    }
}

/// "4.2 · 41,200 votes · Goodreads" with the stars: a number without origin is no statement.
struct Stars: View {

    let rating: Rating

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { i in
                    Image(systemName: Stars.symbol(rating.stars, i))
                        .font(.caption)
                        .foregroundStyle(theme.accent.color)
                }
            }
            // VoiceOver read "star, star, star, half star"; the number says it.
            .accessibilityHidden(true)
            Text(verbatim: Stars.text(rating))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(ColorTheme.muted.color)
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ stars: Double, _ i: Int) -> String {
        let remainder = stars - Double(i)
        if remainder >= 0.75 { return "star.fill" }
        if remainder >= 0.25 { return "star.leadinghalf.filled" }
        return "star"
    }

    static func text(_ b: Rating) -> String {
        var share = [b.stars.formatted(.number.precision(.fractionLength(1)))]
        if let voices = b.voices { share.append(Phrase.from("title.votes", Formats.integer(voices))) }
        share.append(b.origin)
        return share.joined(separator: " · ")
    }
}

/// The "In the book" sheet in the title detail: a view from the ``InBookFactory``.
private struct InBookSheet: Identifiable {
    let id = UUID()
    let viewMode: AnyView
}
