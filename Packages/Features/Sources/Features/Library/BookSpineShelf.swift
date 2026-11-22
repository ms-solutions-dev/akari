import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The shelf view: the library as a real shelf of book spines, which Apple Books and
/// Kindle do not have.
///
/// Each spine carries the title vertically in Newsreader on the color its
/// ``TitlePlaceholder`` would have, stable from the title, so the same book has the same
/// color on the shelf and as a placeholder. The width follows the extent (pages or
/// duration), the height varies slightly so it looks like a shelf and not a table. A tap
/// pulls the spine out a little and zooms into the detail.
struct BookSpineShelf<Header: View>: View {

    let kind: Kind?
    @ViewBuilder let header: Header

    @Environment(LibraryService.self) private var inventory
    /// The usable width, measured so the boards carry as many spines as fit.
    @State private var width: CGFloat = 360
    /// The spines from the catalog, page by page; with 35,000 books not all at once.
    @State private var list = CatalogList()

    private var question: CatalogList.EntryKey {
        let a = inventory.catalogQuery(kind: kind, sorting: .title)
        return CatalogList.EntryKey(
            query: a, unfiltered: a, bundled: inventory.bookSeriesList, catalog: inventory.catalogState,
            readingState: inventory.readingStateState)
    }

    var body: some View {
        let entries =
            inventory.catalog != nil
            ? list.entries : inventory.parts(kind: kind, sorting: .title).flatMap(\.entries)
        let bookSeriesList = BookSpineShelf.board(entries, width: max(width - 32, 200))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                ForEach(bookSeriesList.indices, id: \.self) { i in
                    BoardRow(entries: bookSeriesList[i])
                        .padding(.horizontal, 16)
                        .onAppear { if let last = bookSeriesList[i].last { list.appears(last.id) } }
                }
            }
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .paper()
        .task(id: question) { await list.question(question, catalog: inventory.catalog) }
    }

    /// Entries distributed onto boards, as many as fit the width.
    static func board(_ entries: [Shelf.Item], width: CGFloat) -> [[Shelf.Item]] {
        var bookSeriesList: [[Shelf.Item]] = [[]]
        var used: CGFloat = 0
        for e in entries {
            let b = BookSpine.width(e) + 2
            if used + b > width, !(bookSeriesList.last?.isEmpty ?? true) {
                bookSeriesList.append([])
                used = 0
            }
            bookSeriesList[bookSeriesList.count - 1].append(e)
            used += b
        }
        return bookSeriesList.filter { !$0.isEmpty }
    }
}

/// A board with its spines, bottom-aligned, with the wood below.
private struct BoardRow: View {

    let entries: [Shelf.Item]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(entries) { entry in
                    NavigationLink(value: BookSpine.target(entry)) {
                        BookSpine(entry: entry)
                    }
                    .buttonStyle(PullOutStyle())
                    .zoomSource(BookSpine.target(entry))
                }
                Spacer(minLength: 0)
            }
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.66, green: 0.45, blue: 0.27),
                            Color(red: 0.52, green: 0.34, blue: 0.20),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
                .frame(height: 9)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
        }
    }
}

/// A book spine: color from the title, title vertical, a fine gold line at the top.
private struct BookSpine: View {

    let entry: Shelf.Item

    var body: some View {
        let name = BookSpine.name(entry)
        let height = BookSpine.height(entry)
        ZStack {
            TitlePlaceholder.audio(name).color
            // Curvature of the spine: light on the left, shadow on the right.
            LinearGradient(
                colors: [.white.opacity(0.16), .clear, .black.opacity(0.22)], startPoint: .leading,
                endPoint: .trailing)
            VStack(spacing: 6) {
                Rectangle().fill(Color(red: 0.85, green: 0.72, blue: 0.45).opacity(0.7)).frame(height: 1)
                    .padding(.horizontal, 4)
                Text(verbatim: name)
                    .font(Typography.title(.caption, weight: .semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.97, blue: 0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: height - 36)
                    .rotationEffect(.degrees(90))
                    .frame(width: BookSpine.width(entry), height: height - 36)
                Rectangle().fill(Color(red: 0.85, green: 0.72, blue: 0.45).opacity(0.7)).frame(height: 1)
                    .padding(.horizontal, 4)
            }
            .padding(.vertical, 10)
        }
        .frame(width: BookSpine.width(entry), height: height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isLink)
    }

    static func target(_ e: Shelf.Item) -> Target {
        switch e {
        case .series(let s): .series(s.identifier)
        case .title(let t): .title(t.identifier)
        }
    }

    static func name(_ e: Shelf.Item) -> String {
        switch e {
        case .series(let s): s.name
        case .title(let t): Display(t, inBookSeries: false).name
        }
    }

    /// 24-44 pt: thin books narrow, tomes wide; series a little wider.
    static func width(_ e: Shelf.Item) -> CGFloat {
        switch e {
        case .series: return 40
        case .title(let t):
            switch t.scope {
            case .pages(let n): return 24 + min(20, CGFloat(n) / 40)
            case .duration(let s): return 24 + min(20, CGFloat(s) / 3600 * 1.2)
            case .unknown: return 30
            }
        }
    }

    /// 160-196 pt, stable from the name.
    static func height(_ e: Shelf.Item) -> CGFloat {
        let audio = TitlePlaceholder.audio(name(e))
        return 160 + CGFloat(audio.light % 37)
    }
}

/// When pressed, a spine is pulled a little out of the shelf.
private struct PullOutStyle: ButtonStyle {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed && !reduceMotion ? -16 : 0)
            // The shadow only while pressed: with color opacity zero the blur pass still
            // ran for each of the hundred spines. Core Animation does not draw a layer
            // with zero opacity at all.
            .background {
                Rectangle()
                    .fill(.black)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 6)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(Motion.bounce(reduceMotion), value: configuration.isPressed)
    }
}
