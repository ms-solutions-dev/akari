import DesignSystem
import SwiftUI

/// "In the book": what the book knows about itself - people, places,
/// terms from its glossary and the map with all located terms. With
/// **"Only up to here"** (default on) whatever first appears after the current position is missing
/// - spoiler protection on word positions.
///
/// A tap on an entry opens its sheet. If the book has no index, that is shown
/// honestly - nothing is faked.
struct InBookView: View {

    enum Part: String, CaseIterable, Identifiable {
        case people = "personen", places = "orte", terms = "begriffe", card = "karte"
        var id: String { rawValue }
    }

    let glossary: Glossary?
    let terms: TermIndex?
    let wordHere: Int?
    let cards: [BookCard]
    let theme: ReadingStyle.ReadingTheme
    /// Opens the sheet for an entry.
    let open: (Glossary.Item) -> Void

    @State private var part: Part = .people
    @State private var onlyUntilHere = true

    var body: some View {
        NavigationStack {
            Group {
                if let glossary = shown {
                    content(glossary)
                } else {
                    Text(app: "inBook.keinGlossar")
                        .font(.subheadline)
                        .foregroundStyle(theme.inkColor.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                }
            }
            .background(theme.paperColor)
            .navigationTitle(Text(app: "book.inBook"))
            .toolbarTitleDisplayMode(.inline)
        }
        .presentationBackground(theme.paperColor)
        .onAppear { part = available.first ?? .terms }
        .onChange(of: cards.count) {
            if !available.contains(part) { part = available.first ?? .terms }
        }
    }

    /// Without a glossary but with a map: an empty one, so the map section appears.
    private var shown: Glossary? { glossary ?? (cards.isEmpty ? nil : .empty) }

    /// Only the parts that show something.
    private var available: [Part] {
        guard let glossary = shown else { return [] }
        var t: [Part] = []
        if glossary.entries.contains(where: { kind($0) == .person }) { t.append(.people) }
        if glossary.entries.contains(where: { kind($0) == .place }) { t.append(.places) }
        if glossary.entries.contains(where: { kind($0) == .term }) { t.append(.terms) }
        if !cards.isEmpty { t.append(.card) }
        return t
    }

    @ViewBuilder
    private func content(_ glossary: Glossary) -> some View {
        List {
            Section {
                Picker(selection: $part) {
                    ForEach(available) { t in
                        Text(appKey: "inBook." + t.rawValue).tag(t)
                    }
                } label: {
                    Text(app: "book.inBook")
                }
                .pickerStyle(.segmented)
                if wordHere != nil, terms != nil {
                    Toggle(isOn: $onlyUntilHere) {
                        Label(app: "inBook.nurBisHier", systemImage: "eye.slash")
                    }
                }
            }
            .listRowBackground(Color.clear)
            if part == .card {
                ForEach(cards) { card in
                    CardImage(card: card, visible: visible(card))
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(list(glossary)) { e in
                        Button {
                            open(e)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: e.term)
                                    .font(Typography.title(.body, weight: .semibold))
                                    .foregroundStyle(theme.inkColor)
                                if !e.explanation.isEmpty {
                                    Text(verbatim: InBookView.firstSentence(e.explanation))
                                        .font(.footnote)
                                        .foregroundStyle(theme.inkColor.opacity(0.7))
                                        .lineLimit(2)
                                }
                            }
                        }
                        .listRowBackground(theme.paperColor)
                    }
                } footer: {
                    Text(verbatim: Wording.phrase("inBook.eintraege", list(glossary).count))
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func known(_ id: String) -> Bool {
        guard onlyUntilHere, let terms, let wordHere else { return true }
        return terms.known(id, until: wordHere)
    }

    private func kind(_ e: Glossary.Item) -> Glossary.Variant {
        e.display(onCard: cards.contains { $0.places[e.id] != nil })
    }

    private func list(_ glossary: Glossary) -> [Glossary.Item] {
        glossary.entries.filter { e in
            let matches: Bool
            switch part {
            case .people: matches = kind(e) == .person
            case .places: matches = kind(e) == .place
            case .terms, .card: matches = kind(e) == .term
            }
            return matches && known(e.id)
        }
    }

    private func visible(_ card: BookCard) -> [String: CGRect] {
        card.places.filter { known($0.key) }
    }

    /// The first sentence of the explanation - "role" in the list.
    static func firstSentence(_ s: String) -> String {
        guard let end = s.range(of: #"[.!?](\s|$)"#, options: .regularExpression) else { return s }
        return String(s[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
    }
}

/// A map with all visible pins and the line "4 of 6 places located".
private struct CardImage: View {

    let card: BookCard
    let visible: [String: CGRect]

    @State private var image: CGImage?
    @State private var quarter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                RotatedCard(image: image, pins: visible, quarter: quarter)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
            HStack {
                if !card.places.isEmpty {
                    Text(verbatim: Wording.phrase("inBook.verortet", visible.count, card.places.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CardRotateButton(quarter: $quarter)
            }
        }
        .task {
            let data = card.data
            image = await Task.detached { CardFinder.image(data) }.value
        }
    }
}
