import AccountsKit
import DesignSystem
import Library
import Metadata
import OfflineStore
import SourcesKit
import SwiftUI

/// The author page: the header on top (image, life dates, a paragraph from
/// Wikipedia if the user has enabled it), below it everything by the author from
/// all sources, bundled by series. Reachable from the title and series detail,
/// from search and from the library's authors view.
struct AuthorView: View {

    let name: String
    @Environment(LibraryService.self) private var inventory

    var body: some View {
        let display = AuthorName.display(name)
        ShelfView(kind: nil, genre: nil, author: name, preset: Sorting.defaultInGenre(for:)) {
            AuthorHeader(
                name: display, counter: AuthorView.counter(name, inventory.authors()),
                reference: inventory.shelf.authorReference(name))
        }
        .titleOnScroll(Text(verbatim: display))
    }

    /// "3 books · 2 audiobooks": titles per kind, counted from the catalog.
    static func counter(_ name: String, _ authors: [Shelf.Author]) -> String {
        let k = AuthorName.lookupKey(name)
        guard let author = authors.first(where: { $0.lookupKey == k }) else { return "" }
        return AuthorHeader.counterText(author.count)
    }
}

/// The authors in title and series detail: every name is a link to their page,
/// for all sources (not only Grimmory). For manga with illustrators: "Story: Gihousglo Flanplias
/// · Art: Siari Spaisla", the names within are the links.
struct AuthorLinks: View {

    let names: [String]
    var illustrators: [String] = []

    var body: some View {
        // Running text built from Text concatenation cannot carry links, hence a
        // wrapping row of buttons with commas in between.
        FlowLayout(spacing: 0) {
            if !illustrators.isEmpty {
                Text(app: "series.text.short").foregroundStyle(ColorTheme.muted.color)
            }
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                link(name, comma: i < names.count - 1)
            }
            if !illustrators.isEmpty {
                Text(verbatim: " · ").foregroundStyle(ColorTheme.muted.color)
                Text(app: "series.drawing.short").foregroundStyle(ColorTheme.muted.color)
                ForEach(Array(illustrators.enumerated()), id: \.offset) { i, name in
                    link(name, comma: i < illustrators.count - 1)
                }
            }
        }
        .font(.subheadline)
    }

    private func link(_ name: String, comma: Bool) -> some View {
        NavigationLink(value: Target.author(name)) {
            HStack(spacing: 2) {
                Text(verbatim: AuthorName.display(name) + (comma ? "," : ""))
                if !comma { Image(systemName: "chevron.right").font(.caption2) }
            }
            .padding(.trailing, comma ? 4 : 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

/// A wrapping row: whatever no longer fits on the line moves to the next.
struct FlowLayout: Layout {

    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrangement(subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrangement(subviews, width: bounds.width)
        for (i, point) in placement.points.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for part in subviews {
            let mass = part.sizeThatFits(.unspecified)
            if x > 0, x + mass.width > width {
                x = 0
                y += rowHeight + 2
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += mass.width + spacing
            rowHeight = max(rowHeight, mass.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}

/// The author page header. **The user's own server first:** Grimmory keeps authors
/// with image and description (Audible match), and those come without a switch since
/// it is the user's own house. Wikipedia only supplements what is missing: life dates
/// always (no server knows them), image and paragraph only without a server image or
/// description, and only with the switch on.
///
/// Switch off: below the server data an invitation with one sentence on what happens.
/// Never a spinner: the header shows at once with name and counter, image and text are
/// added as they arrive.
struct AuthorHeader: View {
    /// "Reduce Motion": then no animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let name: String
    let counter: String
    /// The entry on the server: Grimmory; `nil` for Komga and Audiobookshelf.
    var reference: AuthorReference? = nil

    @AppStorage(AuthorHeader.wikipediaKey) private var wikipedia = false
    @Environment(LibraryService.self) private var inventory
    @Environment(\.authorLookup) private var lookup
    @Environment(\.openURL) private var open
    @Environment(\.profile) private var reader
    @State private var profile: AuthorProfile?
    @State private var server: SourceAuthor?
    @State private var unresolved = false

    static let wikipediaKey = "autoren.wikipedia"

    /// The image: from the server, otherwise Wikipedia.
    private var image: (address: URL?, source: SourceID?) {
        if let b = reference?.image { return (b, reference?.source) }
        return (profile?.image, nil)
    }

    /// The paragraph: from the server (without HTML), otherwise Wikipedia.
    private var text: String? {
        if let t = server?.descriptionText.map(Summary.cleaned), !t.isEmpty { return t }
        return profile?.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                AuthorImage(name: name, address: image.address, source: image.source)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: profile?.name ?? name)
                        .font(Typography.title(.title2))
                        .foregroundStyle(ColorTheme.typography.color)
                    if let profile, let data = AuthorHeader.lifeDates(profile) {
                        Text(verbatim: data)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(ColorTheme.muted.color)
                    }
                    if let short = profile?.short {
                        Text(verbatim: short)
                            .font(.subheadline)
                            .foregroundStyle(ColorTheme.typography.color)
                    }
                    if !counter.isEmpty {
                        Text(verbatim: counter)
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(ColorTheme.muted.color)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let text {
                Text(verbatim: text)
                    .font(Typography.title(.subheadline, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(ColorTheme.typography.color)
                    .lineLimit(unresolved ? nil : 4)
                    .readingWidth()
            }
            HStack(spacing: 16) {
                if (text?.count ?? 0) > 200 {
                    Button {
                        withAnimation(Motion.soft(reduceMotion)) { unresolved.toggle() }
                    } label: {
                        Text(app: unresolved ? "text.fewer" : "text.more")
                    }
                }
                if let article = profile?.article {
                    Button {
                        open(article)
                    } label: {
                        Label(app: "author.wikipedia", systemImage: "arrow.up.right")
                    }
                }
            }
            .font(.subheadline.weight(.medium))
            if !wikipedia, !reader.kind {
                invitation
            }
        }
        .padding(.horizontal)
        .task(id: reference?.id) {
            guard let reference, let source = inventory.source(reference.source) else { return }
            server = try? await source.author(reference)
        }
        .task(id: wikipedia) {
            guard wikipedia else { return }
            profile = await lookup.profile(name)
        }
    }

    /// The invitation to flip the switch, here where one sees what is missing, not
    /// in the account sheet. The sentence says what happens.
    private var invitation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app: "author.invitation")
                .font(.footnote)
                .foregroundStyle(ColorTheme.muted.color)
                .readingWidth()
            Button {
                wikipedia = true
            } label: {
                Label(app: "author.turnOn", systemImage: "person.text.rectangle")
            }
            .font(.subheadline.weight(.medium))
        }
    }

    /// "* 14 March 1958 · † 2 May 2019", with the signs encyclopedias use; without
    /// a death date only the birth, without both nothing.
    static func lifeDates(_ profile: AuthorProfile) -> String? {
        var share: [String] = []
        if let g = profile.born { share.append("* " + g.text()) }
        if let t = profile.died { share.append("† " + t.text()) }
        return share.isEmpty ? nil : share.joined(separator: " · ")
    }

    /// "3 books · 2 audiobooks" in the order of the kinds.
    static func counterText(_ count: [Kind: Int]) -> String {
        Kind.allCases.compactMap { kind -> String? in
            guard let n = count[kind], n > 0 else { return nil }
            switch kind {
            case .manga: return Phrase.from("counter.volumes", n)
            case .book: return Phrase.from("counter.books", n)
            case .audiobook: return Phrase.from("counter.audiobooks", n)
            case .podcast: return Phrase.from("counter.episodes", n)
            }
        }
        .joined(separator: " · ")
    }
}

/// The author's image: round, 88 pt; without an image the initials on paper. The image
/// comes through the ``OfflineStore/ImageLoader`` (memory, disk): from the user's own server
/// with its headers and transport, from Commons without.
struct AuthorImage: View {

    let name: String
    let address: URL?
    /// The source if the image comes from the user's own server, for headers and
    /// the certificate guard; `nil` for Wikipedia.
    var source: SourceID? = nil
    var size: CGFloat = 88

    @Environment(LibraryService.self) private var inventory
    @Environment(\.imageTransport) private var transport
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Circle().fill(theme.surface.color)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(verbatim: AuthorName.initials(name))
                    .font(Typography.title(size > 60 ? .title2 : .subheadline))
                    .foregroundStyle(ColorTheme.muted.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ColorTheme.muted.color.opacity(0.25), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: address) {
            guard let address else { return }
            image = await ImageLoader.shared.image(
                address, headerLines: source.map(inventory.headerLines) ?? [:],
                pixels: Int(size * displayScale * 1.5),
                transport: source.map { transport($0.provider) } ?? URLSession.shared)
        }
    }
}

/// The library's authors view (the fourth view next to title, series,
/// collections): all authors of the chosen kind as rows with image or initials,
/// counter per kind, sections by the first letter of the last name, and the
/// scroll handle, because with 900 books there are a few hundred.
struct AuthorList<Header: View>: View {

    let kind: Kind?
    @ViewBuilder let header: Header

    @Environment(LibraryService.self) private var inventory
    @Environment(\.authorLookup) private var lookup
    @AppStorage(AuthorHeader.wikipediaKey) private var wikipedia = false

    var body: some View {
        let parts = AuthorList.parts(inventory.authors(kind))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: .sectionHeaders) {
                header
                if parts.isEmpty {
                    EmptyState(
                        glyph: "person.2", title: Text(app: "view.authors"),
                        text: Text(app: "author.empty"))
                } else {
                    ForEach(parts, id: \.header) { part in
                        Section {
                            VStack(spacing: 4) {
                                ForEach(part.authors) { author in
                                    NavigationLink(value: Target.author(author.name)) {
                                        AuthorRow(author: author)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        } header: {
                            SectionHeader(header: .text(part.header))
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrubHandle()
        .paper()
        .softEdge()
        .refreshable { await inventory.refresh() }
    }

    struct Part {
        let header: String
        let authors: [Shelf.Author]
    }

    /// By the first letter of the last name; digits and others under "#".
    static func parts(_ authors: [Shelf.Author]) -> [Part] {
        var clusters: [String: [Shelf.Author]] = [:]
        var order: [String] = []
        for author in authors {
            let lastName = author.name.split(separator: " ").last.map(String.init) ?? author.name
            let first = lastName.folding(options: .diacriticInsensitive, locale: nil).uppercased().first
            let header = first.map { $0.isLetter ? String($0) : "#" } ?? "#"
            if clusters[header] == nil { order.append(header) }
            clusters[header, default: []].append(author)
        }
        return order.map { Part(header: $0, authors: clusters[$0]!) }
    }
}

/// A row of the authors view: image from the server, otherwise from the Wikipedia store
/// if already fetched (the list does not query Wikipedia itself), name, counter.
struct AuthorRow: View {

    let author: Shelf.Author
    @Environment(\.authorLookup) private var lookup
    @AppStorage(AuthorHeader.wikipediaKey) private var wikipedia = false
    @State private var wikiImage: URL?

    var body: some View {
        Row(
            name: Text(verbatim: author.name),
            secondaryLine: Text(verbatim: AuthorHeader.counterText(author.count))
        ) {
            if let image = author.reference?.image {
                AuthorImage(name: author.name, address: image, source: author.reference?.source, size: 44)
            } else {
                AuthorImage(name: author.name, address: wikiImage, size: 44)
            }
        }
        .task(id: wikipedia) {
            guard wikipedia, author.reference?.image == nil else { return }
            wikiImage = await lookup.present(author.name)?.image
        }
    }
}

/// The author lookup as environment value, one per app, with its store under the
/// cache; a preview can inject another.
struct AuthorLookupKey: EnvironmentKey {
    static let defaultValue = AuthorLookup(folder: Cache.folder.appending(path: "autoren"))
}

extension EnvironmentValues {
    var authorLookup: AuthorLookup {
        get { self[AuthorLookupKey.self] }
        set { self[AuthorLookupKey.self] = newValue }
    }
}
