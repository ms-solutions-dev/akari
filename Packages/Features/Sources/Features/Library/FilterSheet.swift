import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The filter sheet: status, shelf, genre, author, series, language, format, publisher,
/// year of publication; several at once, OR within a section, AND between sections. Each
/// section shows the most common values with their count, counted under the other
/// criteria ("Crime 418" means that many remain with everything else); "All ..." opens the
/// whole list with search. At the bottom, how many remain.
///
/// The counts come from the ``CatalogIndex``, off the main path: with 35,000 books that is
/// seven queries of a few milliseconds each, and the sheet stays usable.
struct FilterSheet: View {

    @Binding var filtering: Filtering
    let source: FilterSource

    @State private var values = FilterValues()
    @Environment(\.dismiss) private var close

    var body: some View {
        Sheet(title: Text(app: "filter.title")) {
            List {
                Section {
                    Picker(selection: $filtering.phase) {
                        Text(app: "filter.all").tag(ReadStatus?.none)
                        Text(app: "filter.unread").tag(ReadStatus?.some(.unread))
                        Text(app: "filter.started").tag(ReadStatus?.some(.started))
                        Text(app: "filter.read").tag(ReadStatus?.some(.read))
                    } label: {
                        Text(app: "filter.status")
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $filtering.downloaded) { Text(app: "filter.keep") }
                    Toggle(isOn: $filtering.saved) { Text(app: "filter.saved") }
                    Toggle(isOn: $filtering.gaps) { Text(app: "filter.gaps") }
                } header: {
                    Text(app: "filter.status")
                }
                .listRowBackground(Color.clear)

                if !source.shelves.isEmpty {
                    FacetSection(
                        title: Text(app: "filter.shelf"),
                        values: source.shelves.map {
                            FacetSection.Value(
                                value: $0.identifier, name: $0.name,
                                count: values.shelves[$0.identifier] ?? 0,
                                glyph: $0.automatic ? "sparkles" : nil)
                        }.sorted { $0.count > $1.count },
                        chosen: $filtering.shelves, top: 5)
                }
                facet(.genre, title: Text(app: "filter.genre"), chosen: $filtering.genres, top: 6)
                facet(.author, title: Text(app: "filter.author"), chosen: $filtering.authors, top: 5)
                facet(.series, title: Text(app: "filter.bookSeries"), chosen: $filtering.seriesList, top: 5)
                facet(.language, title: Text(app: "filter.language"), chosen: $filtering.languages, top: 5)
                facet(.format, title: Text(app: "filter.format"), chosen: $filtering.formats, top: 5)
                facet(
                    .publisher, title: Text(app: "filter.publisher"), chosen: $filtering.publishers, top: 5)

                if let range = values.years, range.lowerBound < range.upperBound {
                    Section {
                        YearRange(years: $filtering.years, possible: range)
                    } header: {
                        Text(app: "filter.year")
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .paper()
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    if !filtering.empty {
                        Button {
                            filtering = Filtering()
                        } label: {
                            Text(app: "filter.reset")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        close()
                    } label: {
                        Text(verbatim: values.ready ? Phrase.from("filter.show", values.hit) : " ")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    .disabled(values.ready && values.hit == 0)
                }
                .padding()
                .background(.bar)
            }
        }
        .presentationDetents([.large])
        .task(id: filtering) { values = await source.load(filtering) }
    }

    @ViewBuilder
    private func facet(_ field: Facet, title: Text, chosen: Binding<Set<String>>, top: Int) -> some View {
        let list = values.facets[field] ?? []
        // A section with a single value is no choice, unless it is selected.
        if list.count > 1 || !chosen.wrappedValue.isEmpty {
            FacetSection(
                title: title,
                values: list.map {
                    FacetSection.Value(
                        value: $0.value, name: name(field, $0.value), count: $0.count, glyph: nil)
                },
                chosen: chosen, top: top)
        }
    }

    private func name(_ field: Facet, _ value: String) -> String {
        switch field {
        case .language: FilterSheet.languageName(value)
        case .series: values.seriesNames[value] ?? value
        default: value
        }
    }

    /// "German" for `de`, "English (US)" for `en-US`; the code if the device does not
    /// know it.
    static func languageName(_ code: String) -> String {
        let name =
            Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(
                forLanguageCode: code)
        return name?.capitalized(with: .current) ?? code
    }
}

/// A shelf to choose in the filter sheet.
struct ShelfChoice: Sendable, Hashable {
    let identifier: String
    let name: String
    /// Magic Shelf: rule-based on the server.
    let automatic: Bool
}

/// What the filter sheet counts.
struct FilterValues: Sendable {
    var facets: [Facet: [CatalogIndex.FacetValue]] = [:]
    var shelves: [String: Int] = [:]
    var seriesNames: [String: String] = [:]
    var years: ClosedRange<Int>?
    var hit = 0
    var ready = false
}

/// Where the filter sheet gets its numbers: the catalog and the query that a filter state yields.
@MainActor
struct FilterSource {
    let catalog: CatalogIndex
    let bundled: Set<Kind>
    let shelves: [ShelfChoice]
    /// The catalog query for a filter state; kind and place (genre, author) are already in it.
    let query: (Filtering) -> CatalogQuery

    func load(_ filtering: Filtering) async -> FilterValues {
        let main = query(filtering)
        // Per shelf the count if exactly this shelf were chosen, under the other criteria.
        let perShelf: [(String, CatalogQuery)] = shelves.map { r in
            var f = filtering
            f.shelves = [r.identifier]
            return (r.identifier, query(f))
        }
        let catalog = catalog
        let bundled = bundled
        let chosenSeries = Array(filtering.seriesList)
        return await Task.detached(priority: .userInitiated) {
            var w = FilterValues()
            for field in Facet.allCases {
                w.facets[field] = (try? catalog.facet(field, main, atMost: 400)) ?? []
            }
            for (k, a) in perShelf { w.shelves[k] = (try? catalog.count(a)) ?? 0 }
            let seriesList = (w.facets[.series] ?? []).map(\.value) + chosenSeries
            w.seriesNames = (try? catalog.seriesNames(Array(Set(seriesList)))) ?? [:]
            w.years = try? catalog.years(main)
            w.hit = (try? catalog.entryCount(main, bundled: bundled)) ?? 0
            w.ready = true
            return w
        }.value
    }
}

/// A section of the filter sheet: the most common values as rows with checkmark and count,
/// below "All N ..." for the whole list with search. Selected values always stay on top,
/// even if rare, otherwise what one wants to deselect would vanish.
struct FacetSection: View {

    struct Value: Hashable, Identifiable {
        let value: String
        let name: String
        let count: Int
        var glyph: String?
        var id: String { value }
    }

    let title: Text
    let values: [Value]
    @Binding var chosen: Set<String>
    let top: Int

    private var visible: [Value] {
        let chosenFirst = values.filter { chosen.contains($0.value) }
        let remainder = values.filter { !chosen.contains($0.value) }
        return chosenFirst + remainder.prefix(max(0, top - chosenFirst.count))
    }

    var body: some View {
        Section {
            ForEach(visible) { w in
                FacetRow(value: w, chosen: $chosen)
            }
            if values.count > top {
                NavigationLink {
                    FacetList(title: title, values: values, chosen: $chosen)
                } label: {
                    Text(verbatim: Phrase.from("filter.allValues", values.count))
                        .foregroundStyle(Color.accentColor)
                }
            }
        } header: {
            title
        }
        .listRowBackground(Color.clear)
    }
}

/// A row with checkmark: name, count; 0 is dimmed but selectable.
private struct FacetRow: View {
    let value: FacetSection.Value
    @Binding var chosen: Set<String>

    var body: some View {
        let to = chosen.contains(value.value)
        Button {
            Haptics.selection()
            if to { chosen.remove(value.value) } else { chosen.insert(value.value) }
        } label: {
            HStack(spacing: 10) {
                if let glyph = value.glyph {
                    Image(systemName: glyph).foregroundStyle(Color.accentColor)
                }
                Text(verbatim: value.name)
                    .foregroundStyle(
                        value.count == 0 && !to ? ColorTheme.muted.color : ColorTheme.typography.color
                    )
                    .lineLimit(2)
                Spacer()
                Text(verbatim: Formats.integer(value.count))
                    .font(.footnote).monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
                Image(systemName: to ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(to ? Color.accentColor : ColorTheme.muted.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(to ? .isSelected : [])
    }
}

/// The whole list of a section, with search.
private struct FacetList: View {
    let title: Text
    let values: [FacetSection.Value]
    @Binding var chosen: Set<String>
    @State private var search = ""

    private var matching: [FacetSection.Value] {
        let s = search.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return values }
        return values.filter { $0.name.localizedCaseInsensitiveContains(s) }
    }

    var body: some View {
        List(matching) { w in
            FacetRow(value: w, chosen: $chosen)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .searchable(text: $search)
        .paper()
        .navigationTitle(title)
    }
}

/// From-to as two wheels side by side; one year is enough, no date picker. The toggle in
/// front: without it "all years" applies.
struct YearRange: View {

    @Binding var years: ClosedRange<Int>?
    let possible: ClosedRange<Int>

    var body: some View {
        Toggle(isOn: Binding(get: { years != nil }, set: { years = $0 ? possible : nil })) {
            Text(app: "filter.year.narrowDown")
        }
        if let range = years {
            HStack(spacing: 0) {
                rad(
                    Text(app: "filter.year.from"),
                    value: Binding(
                        get: { range.lowerBound }, set: { years = $0...max($0, range.upperBound) }))
                rad(
                    Text(app: "filter.year.until"),
                    value: Binding(
                        get: { range.upperBound }, set: { years = min($0, range.lowerBound)...$0 }))
            }
            .frame(height: 140)
        }
    }

    private func rad(_ title: Text, value: Binding<Int>) -> some View {
        VStack(spacing: 0) {
            title.font(.caption).foregroundStyle(ColorTheme.muted.color)
            Picker(selection: value) {
                ForEach(Array(possible), id: \.self) { year in
                    Text(verbatim: String(year)).tag(year)
                }
            } label: {
                title
            }
            #if os(iOS)
                .pickerStyle(.wheel)
            #endif
            .labelsHidden()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The active criteria as chips above the grid, each with a cross, and "Clear" for all.
/// So what is filtered is visibly there.
struct FilterChips: View {

    @Binding var filtering: Filtering
    /// With its own side margin; in the ``GridHeader`` the header carries it.
    var withEdge = true
    /// Names for shelves and series; the criteria are identifiers.
    var names = FilterNames()

    var body: some View {
        ChipRow {
            ForEach(FilterChips.chips(filtering, names: names), id: \.self) { chip in
                Button {
                    filtering = FilterChips.without(chip, filtering)
                } label: {
                    HStack(spacing: 6) {
                        if let glyph = chip.glyph {
                            Image(systemName: glyph).font(.caption.weight(.semibold))
                        }
                        Text(verbatim: chip.text).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: Phrase.from("filter.chip.remove", chip.text)))
            }
            Button {
                Haptics.selection()
                filtering = Filtering()
            } label: {
                Text(app: "filter.showAll")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
            }
        }
        .padding(.horizontal, withEdge ? 16 : 0)
    }

    struct Chip: Hashable {
        enum Kind: Hashable {
            case phase, downloaded, saved, gaps, years, language(String), format(String),
                publisher(String), shelf(String), genre(String), author(String), series(String)
        }
        let kind: Kind
        let text: String
        var glyph: String?
    }

    /// Order as in the sheet: status, shelf, genre, author, series, then the rest.
    static func chips(_ f: Filtering, names: FilterNames = FilterNames()) -> [Chip] {
        var chips: [Chip] = []
        if let z = f.phase {
            let lookupKey =
                switch z {
                case .unread: "filter.unread"
                case .started: "filter.started"
                case .read: "filter.read"
                }
            chips.append(Chip(kind: .phase, text: Phrase.from(lookupKey)))
        }
        if f.downloaded { chips.append(Chip(kind: .downloaded, text: Phrase.from("filter.keep"))) }
        if f.saved { chips.append(Chip(kind: .saved, text: Phrase.from("filter.saved"))) }
        if f.gaps { chips.append(Chip(kind: .gaps, text: Phrase.from("filter.gaps"))) }
        for r in f.shelves.sorted() {
            let name = names.shelves[r]
            chips.append(
                Chip(
                    kind: .shelf(r), text: name?.name ?? r,
                    glyph: name?.automatic == true ? "sparkles" : "books.vertical"))
        }
        for g in f.genres.sorted() { chips.append(Chip(kind: .genre(g), text: g)) }
        for a in f.authors.sorted() { chips.append(Chip(kind: .author(a), text: a)) }
        for r in f.seriesList.sorted() {
            chips.append(Chip(kind: .series(r), text: names.seriesList[r] ?? r))
        }
        if let j = f.years {
            let text = j.lowerBound == j.upperBound ? String(j.lowerBound) : "\(j.lowerBound)–\(j.upperBound)"
            chips.append(Chip(kind: .years, text: text))
        }
        for s in f.languages.sorted() {
            chips.append(Chip(kind: .language(s), text: FilterSheet.languageName(s)))
        }
        for s in f.formats.sorted() { chips.append(Chip(kind: .format(s), text: s)) }
        for s in f.publishers.sorted() { chips.append(Chip(kind: .publisher(s), text: s)) }
        return chips
    }

    static func without(_ chip: Chip, _ f: Filtering) -> Filtering {
        var f = f
        switch chip.kind {
        case .phase: f.phase = nil
        case .downloaded: f.downloaded = false
        case .saved: f.saved = false
        case .gaps: f.gaps = false
        case .years: f.years = nil
        case .language(let s): f.languages.remove(s)
        case .format(let s): f.formats.remove(s)
        case .publisher(let s): f.publishers.remove(s)
        case .shelf(let s): f.shelves.remove(s)
        case .genre(let s): f.genres.remove(s)
        case .author(let s): f.authors.remove(s)
        case .series(let s): f.seriesList.remove(s)
        }
        return f
    }
}

/// Names for the identifiers in the filter, for the chips.
struct FilterNames: Hashable {
    var shelves: [String: ShelfChoice] = [:]
    var seriesList: [String: String] = [:]
}
