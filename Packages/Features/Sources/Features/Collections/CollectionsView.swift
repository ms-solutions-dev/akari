import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The "Collections" row in the library: Grimmory shelves, Komga collections and reading
/// lists, Audiobookshelf collections and playlists as cards like the genres, with three
/// covers and the count; absent if no source has any. With a kind selected, only the
/// collections containing something of that kind.
struct CollectionRow: View {

    let kind: Kind?
    @Environment(LibraryService.self) private var inventory
    @Environment(\.dynamicTypeSize) private var fontSize

    var body: some View {
        let collections = CollectionRow.matching(inventory, kind: kind)
        if !collections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                RowHeader(
                    title: Text(app: "collection.title"),
                    all: collections.count > 4 ? .allCollections(kind) : nil)
                if fontSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        ForEach(collections) { s in
                            NavigationLink(value: Target.collection(s.identifier)) {
                                Row(
                                    name: Text(verbatim: s.name),
                                    secondaryLine: Text(verbatim: CollectionRow.line(s, inventory))
                                ) {
                                    Image(systemName: CollectionRow.glyph(s))
                                        .foregroundStyle(ColorTheme.muted.color)
                                        .frame(width: 30)
                                }
                            }
                            .buttonStyle(.plain)
                            .asFilterMenu(.shelf(s.identifier.description))
                        }
                    }
                    .padding(.horizontal)
                } else {
                    TileRow {
                        ForEach(collections) { s in
                            NavigationLink(value: Target.collection(s.identifier)) {
                                GenreCard(
                                    name: Text(verbatim: s.name),
                                    count: Text(verbatim: CollectionRow.line(s, inventory)),
                                    cover: inventory.cover(for: s).map {
                                        Cover($0.address, source: $0.source, kind: $0.kind, width: 34)
                                    })
                            }
                            .buttonStyle(.plain)
                            .asFilterMenu(.shelf(s.identifier.description))
                        }
                    }
                }
            }
            .swipeLocked()
        }
    }

    /// All collections, or those containing something of the kind; an empty collection is
    /// listed under "All" so it can be filled.
    @MainActor
    static func matching(_ inventory: LibraryService, kind: Kind?) -> [TitleCollection] {
        guard let kind else { return inventory.shelf.collections }
        return inventory.shelf.collections.filter { s in inventory.overview(in: s).kinds.contains(kind) }
    }

    /// "12 titles": what the shelf knows of it; "Reading list" or "for everyone" as suffix.
    @MainActor
    static func line(_ s: TitleCollection, _ inventory: LibraryService) -> String {
        var share = [Phrase.from("collection.counter", inventory.overview(in: s).count)]
        if s.collectionKind == .readingList { share.append(Phrase.from("collection.readingList")) }
        // A Magic Shelf is always for everyone; saying so would only be noise.
        if !s.isPrivate, !s.automatic { share.append(Phrase.from("collection.forAll")) }
        return share.joined(separator: " · ")
    }

    /// The Lucide icon of a Magic Shelf as an SF Symbol (the common ones); otherwise
    /// sparkles, the sign for automatic.
    static func automaticIcon(_ lucide: String?) -> String {
        switch lucide {
        case "film": "film"
        case "award": "rosette"
        case "star": "star"
        case "library": "books.vertical"
        case "zap": "bolt"
        case "book-open": "book"
        // Built from parts: as text with a period, the localization key check would take it for one.
        case "laugh": "face" + ".smiling"
        case "ghost": "theatermasks"
        case "coffee": "cup" + ".and.saucer"
        case "heart": "heart"
        case "flame": "flame"
        case "crown": "crown"
        default: "sparkles"
        }
    }

    static func glyph(_ s: TitleCollection) -> String {
        if s.automatic { return automaticIcon(s.symbol) }
        return switch s.collectionKind {
        case .shelf: "books.vertical"
        case .collection: "square.stack"
        case .readingList: "list.number"
        }
    }
}

/// The page of a collection: the same grid, narrowed to it and ordered as the server
/// orders it.
struct CollectionView: View {

    let identifier: CollectionID
    @Environment(LibraryService.self) private var inventory

    var body: some View {
        if let collection = inventory.shelf.collection(identifier) {
            ShelfView(kind: nil, genre: nil, collection: identifier, preset: { _ in .title }) {
                if !collection.isPrivate || collection.collectionKind == .readingList {
                    Text(verbatim: CollectionRow.line(collection, inventory))
                        .font(.footnote)
                        .foregroundStyle(ColorTheme.muted.color)
                        .padding(.horizontal)
                }
            }
            .navigationTitle(Text(verbatim: collection.name))
            .toolbarTitleDisplayMode(.inline)
        } else {
            EmptyState(glyph: "questionmark.square.dashed", title: Text(app: "error.notFound"))
        }
    }
}

/// "All collections" as a list.
struct AllCollectionsView: View {

    let kind: Kind?
    @Environment(LibraryService.self) private var inventory

    var body: some View {
        List(CollectionRow.matching(inventory, kind: kind)) { s in
            NavigationLink(value: Target.collection(s.identifier)) {
                LabeledContent {
                    Text(verbatim: Formats.integer(inventory.entries(in: s).count)).monospacedDigit()
                } label: {
                    Label {
                        Text(verbatim: s.name)
                    } icon: {
                        Image(systemName: CollectionRow.glyph(s))
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .paper()
        .navigationTitle(Text(app: "collection.title"))
        .toolbarTitleDisplayMode(.inline)
    }
}

/// "Add to collection...": a submenu in the context menu, a chip menu in the detail view.
/// It lists the source's collections that accept this target and that the account may edit,
/// with a checkmark where it is already in, plus "New collection...". For Komga "for
/// everyone" is added: what the admin creates, the parents see.
struct CollectionMenu: View {

    let target: SaveTarget
    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices
    @Environment(CollectionQuestion.self) private var question

    var body: some View {
        let matching = CollectionMenu.matching(inventory.shelf, target: target)
        if inventory.shelf.capabilities[target.source]?.contains(.editCollections) == true {
            Menu {
                ForEach(matching) { s in
                    let inside = s.contains(target)
                    Button {
                        notices.tryRun {
                            try await inventory.arrange(target, in: s.identifier, into: !inside)
                            Haptics.selection()
                        }
                    } label: {
                        Label {
                            Text(
                                verbatim: s.isPrivate
                                    ? s.name : s.name + " · " + Phrase.from("collection.forAll"))
                        } icon: {
                            Image(systemName: inside ? "checkmark" : CollectionRow.glyph(s))
                        }
                    }
                }
                if !matching.isEmpty { Divider() }
                Button {
                    question.target = target
                } label: {
                    Label(app: "collection.new", systemImage: "plus")
                }
            } label: {
                Label(app: "collection.to", systemImage: "square.stack")
            }
        }
    }

    static func matching(_ shelf: Shelf, target: SaveTarget) -> [TitleCollection] {
        let series = if case .series = target { true } else { false }
        return shelf.collections.filter {
            $0.identifier.source == target.source && $0.editable && $0.collectionKind.takesSeries == series
        }
    }
}

/// The prompt for the name of a new collection: one state for the whole shell, because the
/// menu in a context menu cannot hold an alert.
@MainActor
@Observable
final class CollectionQuestion {
    var target: SaveTarget?
}

extension View {
    /// The alert with the name field, once at the shell.
    func collectionQuestion(_ question: CollectionQuestion) -> some View {
        modifier(CollectionQuestionSheet(question: question))
    }
}

private struct CollectionQuestionSheet: ViewModifier {

    @Bindable var question: CollectionQuestion
    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert(
            Text(app: "collection.new.title"),
            isPresented: Binding(get: { question.target != nil }, set: { if !$0 { question.target = nil } })
        ) {
            TextField(text: $name) { Text(app: "collection.new.name") }
            Button {
                guard let target = question.target else { return }
                let input = name.trimmingCharacters(in: .whitespaces)
                name = ""
                guard !input.isEmpty else { return }
                let collectionKind: TitleCollection.CollectionKind =
                    if case .series = target { .collection } else { .readingList }
                notices.tryRun {
                    try await inventory.create(
                        collection: input, for: target, collectionKind: collectionKind)
                    Haptics.success()
                }
            } label: {
                Text(app: "collection.create")
            }
            Button(role: .cancel) {
                name = ""
            } label: {
                Text(app: "action.cancel")
            }
        } message: {
            Text(app: "collection.new.text")
        }
    }
}
