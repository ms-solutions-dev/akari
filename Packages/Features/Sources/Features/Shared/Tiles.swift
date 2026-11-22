import DesignSystem
import Library
import OfflineStore
import SourcesKit
import SwiftUI

/// The tile of a title: cover, name, secondary line, progress. Tappable for the detail,
/// long press for the context menu.
///
/// The secondary line is up to the caller because it says something different per row:
/// "p. 63/205" under Continue reading, "Volume 48 · New" under Up next, the author in the
/// grid. Without a value the author is shown.
struct TitleTile: View {

    let title: Title
    let width: CGFloat
    var secondaryLine: Text?
    /// The kind badge, only where kinds are mixed (Start, "All").
    var withKind = false
    /// Within its own series a volume is called "Volume 1", otherwise by the series.
    var inBookSeries = false

    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock

    var body: some View {
        let state = inventory.readingState(title.identifier)
        let display = Display(title, inBookSeries: inBookSeries)
        NavigationLink(value: Target.title(title.identifier)) {
            Tile(
                name: Text(verbatim: display.name),
                secondaryLine: secondaryLine ?? preset(display, state: state),
                badge: withKind ? Text(verbatim: Phrase.from(title.kind.lookupKey).uppercased()) : nil,
                progress: state?.started == true ? state?.fraction : nil
            ) {
                Cover(title, width: width)
            } character: {
                KeepMark(identifier: title.identifier)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .dimmedWithoutNetwork(title.identifier, available: stock.entry(title.identifier)?.done == true)
        .titleMenu(title)
    }

    /// Without a value: "Volume 1 · p. 8/227" for started items, otherwise "Volume 1" or
    /// "Author · 4.2 ★".
    private func preset(_ display: Display, state: ReadingState?) -> Text? {
        let remainder = state?.started == true ? state.map(Formats.short) : nil
        return display.secondaryLine(remainder, author: title.authors.first, stars: title.rating).map {
            Text(verbatim: $0)
        }
    }
}

/// The tile of a series; secondary line from the series state: "Volume 47 · 46 read" or
/// "3 volumes".
struct SeriesTile: View {

    let series: Series
    let width: CGFloat
    var secondaryLine: Text?
    var withKind = false

    @Environment(LibraryService.self) private var inventory

    var body: some View {
        let state = inventory.seriesState(series.identifier)
        NavigationLink(value: Target.series(series.identifier)) {
            Tile(
                name: Text(verbatim: series.name),
                secondaryLine: secondaryLine ?? Text(verbatim: SeriesTile.line(state, series: series)),
                badge: withKind ? Text(verbatim: Phrase.from(series.kind.lookupKey).uppercased()) : nil,
                progress: state.read > 0 && !state.completed ? state.fraction : nil
            ) {
                Cover(series, width: width)
            } character: {
                if let gaps = inventory.gaps(series.identifier), !gaps.complete {
                    GapMark(count: gaps.count)
                }
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
        .seriesMenu(series)
    }

    /// "Volume 47 · 46 read", "3 volumes · 4.0 ★", "All 12 read". Unread, the tile carries
    /// the stars; started, the state.
    static func line(_ state: Shelf.SeriesState, series: Series? = nil) -> String {
        if state.completed { return Phrase.from("series.allRead.counter", state.total) }
        if let current = state.current, let number = current.series?.volume, state.read > 0 {
            return Formats.volume(number, kind: current.kind) + " · "
                + Phrase.from("series.read.counter", state.read)
        }
        let kind = series?.kind ?? state.current?.kind
        var share = [Phrase.from(Formats.lookupKey("series.volumes.counter", kind: kind), state.total)]
        if let stars = series?.rating { share.append(Formats.stars(stars)) }
        return share.joined(separator: " · ")
    }
}

/// The mark at the bottom right of the cover of a series with missing volumes: "3 MISSING"
/// as a letter-spaced badge in the secondary tone on the paper cushion, placed like the keep
/// mark but without color, because a gap is not a state one brought about. Whoever wants to
/// see it opens the series, where it says which.
struct GapMark: View {

    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        Badge(Text(verbatim: Phrase.from("series.gaps.chip", count)), audio: .muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(theme.paper.color.opacity(0.9), in: Capsule())
    }
}

/// One tile per shelf entry, series or title, as the grid knows them.
struct EntryTile: View {

    let entry: Shelf.Item
    let width: CGFloat
    var withKind = false
    var secondaryLine: Text?

    var body: some View {
        switch entry {
        case .series(let series):
            SeriesTile(series: series, width: width, secondaryLine: secondaryLine, withKind: withKind)
        case .title(let title):
            TitleTile(title: title, width: width, secondaryLine: secondaryLine, withKind: withKind)
        }
    }
}

/// The row for an entry: from the accessibility sizes on it takes the place of the grid,
/// and in the "All" lists on Start.
struct EntryRow: View {

    let entry: Shelf.Item
    var secondaryLine: Text?
    var withKind = false
    var inBookSeries = false
    /// The cover width: 44 in lists, 56 under the hero on Start.
    var coverWidth: CGFloat = 44

    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock

    var body: some View {
        switch entry {
        case .series(let series):
            NavigationLink(value: Target.series(series.identifier)) {
                Row(
                    name: Text(verbatim: series.name),
                    secondaryLine: secondaryLine
                        ?? Text(
                            verbatim: SeriesTile.line(
                                inventory.seriesState(series.identifier), series: series)),
                    badge: withKind ? Text(appKey: series.kind.lookupKey) : nil
                ) {
                    Cover(series, width: coverWidth)
                }
            }
            .buttonStyle(.plain)
            .seriesMenu(series)
        case .title(let title):
            let state = inventory.readingState(title.identifier)
            let display = Display(title, inBookSeries: inBookSeries)
            NavigationLink(value: Target.title(title.identifier)) {
                Row(
                    name: Text(verbatim: display.name),
                    secondaryLine: secondaryLine
                        ?? EntryRow.secondaryLine(title, display: display, state: state),
                    badge: withKind ? Text(appKey: title.kind.lookupKey) : nil,
                    ongoing: state?.started == true, character: stock.rowMark(title.identifier),
                    characterName: Text(app: "keep.onDevice")
                ) {
                    Cover(title, width: coverWidth)
                }
            }
            .buttonStyle(.plain)
            .dimmedWithoutNetwork(title.identifier, available: stock.entry(title.identifier)?.done == true)
            .titleMenu(title)
        }
    }

    static func secondaryLine(_ title: Title, display: Display, state: ReadingState?) -> Text? {
        let remainder = state?.started == true ? state.map(Formats.short) : nil
        return display.secondaryLine(remainder, author: title.authors.first, stars: title.rating).map {
            Text(verbatim: $0)
        }
    }
}

/// The header of a row on Start or in the library: serif title on the left, a quiet "All"
/// link on the right if there is more than the row shows, and a hairline below. It gives
/// the rows their edge where no surface does.
struct RowHeader: View {

    let title: Text
    var all: Target?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                title
                    // Row headers 22 pt semibold.
                    .font(Typography.title(.title2, weight: .semibold))
                    .foregroundStyle(ColorTheme.typography.color)
                    // For the VoiceOver rotor: jump from row to row.
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let all {
                    NavigationLink(value: all) {
                        Text(app: "line.all")
                            .font(.subheadline.weight(.medium))
                    }
                    // VoiceOver reads "All: Continue reading" instead of "All" three times.
                    .accessibilityLabel(Text("\(Text(app: "line.all")): \(title)"))
                }
            }
            Rectangle().fill(theme.hairline.color).frame(height: 1)
        }
        .padding(.horizontal)
    }
}

/// A horizontally scrolling row of tiles: Start and the genre row.
struct TileRow<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                content
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
        .swipeLocked()
    }
}

/// Reports the view's frame to the `SwipeLock`: a horizontal drag that begins here belongs
/// to scrolling, not to the library's segment switch.
///
/// Attached to every scrolling `TileRow` and to the whole row block including the heading
/// ("Genres", "Shelves"): when scrolling with the thumb the drag often begins on the heading
/// or in the gap, and the segment switched there. Tiles were locked, the heading was not.
struct SwipeLocked: ViewModifier {
    @Environment(SwipeLock.self) private var lock: SwipeLock?
    @State private var identifier = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                lock?.frame[identifier] = frame
            }
            .onDisappear { lock?.frame[identifier] = nil }
    }
}

extension View {
    func swipeLocked() -> some View { modifier(SwipeLocked()) }
}

/// The areas where a horizontal drag belongs to scrolling, not to the segment.
@MainActor
@Observable
final class SwipeLock {
    var frame: [UUID: CGRect] = [:]

    func locked(_ point: CGPoint) -> Bool {
        frame.values.contains { $0.contains(point) }
    }
}

/// The tile width in rows and grids: one number per size class so Start and Library share
/// the same images from the cache. The hero is no larger than the grid: at 132 it was
/// heavier than the title it announces.
///
/// On iPad (wide size class) the tiles are 140/150/160 instead of 110/118/110: on 1,032 pt
/// 110 pt covers were postage stamps, three to four in a row and two thirds empty. The
/// three sizes fall to the same step in the `ImageLoader` as the detail cover (edge x 1.5 x
/// 2 rounded to 80 = 480 px), one cache entry per cover, as on iPhone 110 and 118 fall to
/// 560. The values of the narrow size class are unchanged.
enum TileMetrics {
    /// The tile in a horizontally scrolling row (Start, "From the same series").
    static func line(_ width: UserInterfaceSizeClass?) -> CGFloat {
        width == .regular ? 150 : 118
    }

    /// The tile in the grid (Library, genre, series up to 30 volumes).
    static func raster(_ width: UserInterfaceSizeClass?) -> CGFloat {
        width == .regular ? 140 : 110
    }

    /// The large cover: the hero on Start and the detail header; on iPad 160 pt wide (240
    /// tall at 2:3), otherwise like the grid. A 110 pt cover next to 900 pt of text was a
    /// postage stamp.
    static func large(_ width: UserInterfaceSizeClass?) -> CGFloat {
        width == .regular ? 160 : 110
    }

    /// The maximum width of a grid column: the tile plus air, so the grid fills the width
    /// without the covers drifting apart.
    static func gridCap(_ width: UserInterfaceSizeClass?) -> CGFloat {
        raster(width) + 40
    }

    /// The cover in a row: 56 under the hero, 44 in lists.
    static let rowLarge: CGFloat = 56

    /// The text column of a detail header on iPad: the same 520 pt as the continue-reading
    /// card on Start; a button in it is 360 pt wide.
    static let detailColumn: CGFloat = 520
    static let detailButton: CGFloat = 360

    /// The cap for running text (blurb, author paragraph, invitation): 720 pt is about 90
    /// characters per line in the serif; beyond 900 pt the eye lost the line. On iPhone it
    /// never applies.
    static let readingWidth: CGFloat = 720
}

extension View {
    /// Running text at reading width: at most `TileMetrics.readingWidth`, left in the column.
    func readingWidth() -> some View {
        frame(maxWidth: TileMetrics.readingWidth, alignment: .leading)
    }
}

/// The header of a detail: cover beside the text, below it from the accessibility sizes on.
/// Next to a 110 pt cover only six characters per line remained at AX3. The actions
/// (primary button, chips) stand under the header at full width in the narrow size class.
///
/// On iPad (wide size class): text **and** actions form one column of at most
/// `TileMetrics.detailColumn` beside the cover, the bar follows the column, the button sits
/// at its left (`View.detailButton()`). From the accessibility sizes on everything stacks
/// left on iPad too, with the same cap: 520 pt is still three words per line at AX3.
struct DetailHeader<Cover: View, Text: View, Actions: View>: View {

    /// The spacing between header line, button and chips: the series header takes 16, the
    /// title detail 20.
    var spacing: CGFloat = 16
    @ViewBuilder let cover: Cover
    @ViewBuilder let text: Text
    @ViewBuilder let actions: Actions

    @Environment(\.dynamicTypeSize) private var fontSize
    @Environment(\.horizontalSizeClass) private var width

    var body: some View {
        let large = fontSize.isAccessibilitySize
        let arrangement =
            large
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        if width == .regular {
            arrangement {
                cover
                VStack(alignment: .leading, spacing: 16) {
                    text
                    actions
                }
                .frame(maxWidth: TileMetrics.detailColumn, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                arrangement {
                    cover
                    text
                    Spacer(minLength: 0)
                }
                actions
            }
        }
    }
}

extension View {
    /// The primary button in the detail: on iPad 360 pt wide and left in the text column,
    /// from the accessibility sizes on as wide as the column there; in the narrow size
    /// class the full width.
    func detailButton() -> some View {
        modifier(DetailButtonWidth())
    }
}

private struct DetailButtonWidth: ViewModifier {

    @Environment(\.dynamicTypeSize) private var fontSize
    @Environment(\.horizontalSizeClass) private var width

    func body(content: Content) -> some View {
        let cap: CGFloat =
            width == .regular
            ? (fontSize.isAccessibilitySize ? TileMetrics.detailColumn : TileMetrics.detailButton)
            : .infinity
        content.frame(maxWidth: cap, alignment: .leading)
    }
}
