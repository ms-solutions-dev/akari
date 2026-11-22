import DesignSystem
import Library
import Observation
import SourcesKit
import SwiftUI

/// Search: one field, three servers, grouped by kind, local over the shelf and so just
/// as offline. Scopes as the system's search scopes (All, Manga, Books, Audiobooks);
/// before input the recent searches and "Recently read"; volumes as hits under their
/// series; authors as a group of their own. No large title: the search field is the title.
struct SearchView: View {

    @Environment(LibraryService.self) private var inventory
    /// `AKARI_SUCHE=holmes` pre-fills the field for a screenshot.
    @State private var text = ProcessInfo.processInfo.environment["AKARI_SUCHE"] ?? ""
    @State private var kind: Kind?
    @State private var history = SearchHistory()
    /// The result for the latest input, searched off the main path shortly after the last
    /// key. Until the new one arrives, the old one stays (no flicker while typing).
    @State private var found: (input: String, kind: Kind?, result: Shelf.SearchResult)?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(app: "tab.search"))
                .toolbarTitleDisplayMode(.inline)
                .toolbar { AccountButton() }
                .targets()
        }
        .searchable(text: $text, prompt: Text(app: "search.prompt"))
        .searchScopes($kind, activation: .onSearchPresentation) {
            if inventory.shelf.kinds.count > 1 {
                Text(app: "segment.alle").tag(Kind?.none)
                ForEach(inventory.shelf.kinds, id: \.self) { a in
                    Text(appKey: a.segmentKey).tag(Kind?.some(a))
                }
            }
        }
        .onSubmit(of: .search) { history.save(text) }
        .task(id: "\(input)|\(kind?.rawValue ?? "")|\(inventory.catalogState)") {
            let (question, area) = (input, kind)
            guard !question.isEmpty else { return }
            // Wait briefly: whoever types "lotse" does not want five searches.
            if found != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let result = await inventory.searchInBackground(question, kind: area)
            guard !Task.isCancelled else { return }
            found = (question, area, result)
        }
    }

    private var input: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder
    private var content: some View {
        if input.isEmpty {
            previously
        } else if let found {
            result(found.result)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Before input

    @ViewBuilder
    private var previously: some View {
        let recently = Array(inventory.shelf.continueReading.prefix(6))
        if history.entries.isEmpty && recently.isEmpty {
            EmptyState(
                glyph: "magnifyingglass", title: Text(app: "search.prompt"),
                text: Text(app: "search.hint")
            )
            .paper()
        } else {
            List {
                if !history.entries.isEmpty {
                    Section {
                        ForEach(history.entries, id: \.self) { entry in
                            Button {
                                text = entry
                            } label: {
                                Label {
                                    Text(verbatim: entry).foregroundStyle(ColorTheme.typography.color)
                                } icon: {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(ColorTheme.muted.color)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack {
                            Text(app: "search.recentlySearched")
                            Spacer()
                            Button {
                                history.clearOut()
                            } label: {
                                Text(app: "search.clearHistory").font(.footnote)
                            }
                        }
                    }
                }
                if !recently.isEmpty {
                    Section {
                        ForEach(recently) { l in
                            EntryRow(
                                entry: .title(l.title),
                                secondaryLine: Text(verbatim: StartView.statusLine(l)),
                                withKind: true
                            )
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(app: "search.recentlyRead")
                    }
                }
            }
            .listStyle(.plain)
            .paper()
        }
    }

    // MARK: - Result

    @ViewBuilder
    private func result(_ result: Shelf.SearchResult) -> some View {
        if result.empty {
            EmptyState(
                worm: Text(app: "search.nothing.title"),
                text: Text(verbatim: SearchView.nothingText(input, notSearched: notSearched)),
                pose: .seek
            )
            .paper()
        } else {
            List {
                if !notSearched.isEmpty || inventory.fromCache {
                    Section {
                        if inventory.fromCache, let state = inventory.shelf.state {
                            Banner(
                                .offline,
                                text: Text(
                                    verbatim: Phrase.from(
                                        "search.cache",
                                        state.formatted(date: .abbreviated, time: .shortened))))
                        }
                        if !notSearched.isEmpty {
                            Banner(
                                .hint,
                                text: Text(
                                    verbatim: Phrase.from(
                                        "search.notSearched", notSearched.joined(separator: ", "))))
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                ForEach(result.clusters) { cluster in
                    Section {
                        ForEach(cluster.hit) { hit in
                            switch hit {
                            case .title(let title):
                                EntryRow(entry: .title(title), withKind: false)
                                    .listRowBackground(Color.clear)
                            case .series(let series, let volumes):
                                EntryRow(entry: .series(series), withKind: false)
                                    .listRowBackground(Color.clear)
                                ForEach(volumes.prefix(Shelf.volumesPerHit)) { volume in
                                    EntryRow(entry: .title(volume), inBookSeries: true)
                                        .listRowBackground(Color.clear)
                                        .listRowInsets(
                                            EdgeInsets(top: 4, leading: 56, bottom: 4, trailing: 16))
                                }
                                if volumes.count > Shelf.volumesPerHit {
                                    NavigationLink(value: Target.series(series.identifier)) {
                                        Text(
                                            verbatim: Phrase.from(
                                                Formats.lookupKey("search.moreVolumes", kind: series.kind),
                                                volumes.count - Shelf.volumesPerHit)
                                        )
                                        .font(.subheadline)
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 56, bottom: 4, trailing: 16))
                                }
                            }
                        }
                    } header: {
                        Text(verbatim: SearchView.groupHeader(cluster))
                            .font(Typography.name(.subheadline))
                            .foregroundStyle(ColorTheme.muted.color)
                            .textCase(nil)
                    }
                }
                if !result.authors.isEmpty {
                    Section {
                        ForEach(result.authors) { author in
                            NavigationLink(value: Target.author(author.name)) {
                                Row(
                                    name: Text(verbatim: author.name),
                                    secondaryLine: Text(
                                        verbatim: Phrase.from("search.titleCounter", author.count))
                                ) {
                                    Image(systemName: "person")
                                        .foregroundStyle(ColorTheme.muted.color)
                                        .frame(width: 44)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(app: "search.authors")
                            .font(Typography.name(.subheadline))
                            .foregroundStyle(ColorTheme.muted.color)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .paper()
        }
    }

    /// Sources that did not answer at the last refresh **and** have no extract in
    /// persistence: they are not on the shelf, so not in the hits.
    private var notSearched: [String] {
        let onShelf = Set(inventory.shelf.extracts.map(\.source))
        return inventory.failure.keys.filter { !onShelf.contains($0) }.map(\.server).sorted()
    }

    /// "Manga, 3", "Books, 12".
    static func groupHeader(_ cluster: Shelf.SearchResult.Cluster) -> String {
        Phrase.from(cluster.kind.segmentKey) + " · " + Formats.integer(cluster.hit.count)
    }

    static func nothingText(_ input: String, notSearched: [String]) -> String {
        var text = Phrase.from("search.nothing.text", input)
        if !notSearched.isEmpty {
            text += "\n" + Phrase.from("search.notSearched", notSearched.joined(separator: ", "))
        }
        return text
    }
}

/// The recent searches: eight, newest first, deletable (HIG Searching:
/// "provide a way for people to clear it").
@MainActor
@Observable
final class SearchHistory {

    static let storeKey = "search.verlauf"
    static let atMost = 8

    private(set) var entries: [String]
    @ObservationIgnored private let persistence: UserDefaults

    init(persistence: UserDefaults = .standard) {
        self.persistence = persistence
        self.entries = persistence.stringArray(forKey: SearchHistory.storeKey) ?? []
    }

    func save(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        entries.removeAll { $0.caseInsensitiveCompare(input) == .orderedSame }
        entries.insert(input, at: 0)
        if entries.count > SearchHistory.atMost {
            entries.removeLast(entries.count - SearchHistory.atMost)
        }
        persistence.set(entries, forKey: SearchHistory.storeKey)
    }

    func clearOut() {
        entries = []
        persistence.removeObject(forKey: SearchHistory.storeKey)
    }
}
