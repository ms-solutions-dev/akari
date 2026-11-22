import DesignSystem
import SwiftUI

/// The sheet for a tapped term: type and name on top,
/// a monogram for people (no invented portraits), below it the explanation from the
/// book and the state "First in chapter 3 - up to here 19 times" from the
/// ``TermIndex``. Below that all terms for lookup, with a search field -
/// with **spoiler protection**: whatever first appears after the current position is missing.
///
/// The explanation itself can contain spoilers (the author writes the appendix for the end); that
/// cannot be checked without understanding the text and stays visible.
struct GlossarySheet: View {
    /// "Reduce Motion": then without animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entry: Glossary.Item
    let glossary: Glossary?
    let theme: ReadingStyle.ReadingTheme
    /// Where the terms are in the book - `nil` while counting runs.
    var terms: TermIndex?
    /// The word position of the current spot.
    var wordHere: Int?
    /// The chapter name for a word position (from the table of contents).
    var chapterName: @MainActor (Int) -> String? = { _ in nil }
    /// The book's maps (``BookCard``) - empty while searching or when there are none.
    var cards: [BookCard] = []
    /// On iPhone: pull the sheet large - when the list opens or the map appears
    /// (as before: first as small as the term, then it grows).
    var large: () -> Void = {}
    /// Swipe left/right in the sheet: keep paging (`true` = to the next page in
    /// swipe direction left) - the reader closes the sheet and pages.
    var swipe: (_ links: Bool) -> Void = { _ in }
    /// "All people" on a person leads to "In the book" - `nil` without a button.
    var allPeople: (() -> Void)? = nil
    /// Aa "Show explanations only after tap".
    var covered = false
    /// "All places": list with sentence excerpt, jump - `nil` without a button.
    var allPlaces: ((Glossary.Item) -> Void)? = nil

    @State private var cardOpen = false
    @State private var revealed = false

    @State private var all = false
    @State private var search = ""
    @State private var chosen: Glossary.Item?

    private var current: Glossary.Item { chosen ?? entry }

    var body: some View {
        if cardOpen, let card = cardFor(current) {
            CardView(
                card: card, frame: card.places[current.id], name: current.term, theme: theme,
                done: { cardOpen = false })
        } else {
            explanation
        }
    }

    /// The map for a term: the one on which it is labelled; for a place without a
    /// label the first map of the book (then without a pin).
    private func cardFor(_ e: Glossary.Item) -> BookCard? {
        cards.first { $0.places[e.id] != nil } ?? (kind(e) == .place ? cards.first : nil)
    }

    private func kind(_ e: Glossary.Item) -> Glossary.Variant {
        e.display(onCard: cards.contains { $0.places[e.id] != nil })
    }

    private var explanation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // Map names without a glossary entry have no explanation - then only the map.
                if !current.explanation.isEmpty, covered, !revealed {
                    Button {
                        withAnimation(Motion.soft(reduceMotion)) { revealed = true }
                    } label: {
                        Label(app: "glossary.explanationShow", systemImage: "eye")
                            .font(.subheadline.weight(.medium))
                    }
                } else if !current.explanation.isEmpty {
                    Text(verbatim: current.explanation)
                        .font(Typography.title(.body, weight: .regular))
                        .lineSpacing(4)
                        .foregroundStyle(theme.inkColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let state = statusLine(current) {
                    Text(verbatim: state)
                        .font(.footnote)
                        .foregroundStyle(theme.inkColor.opacity(0.6))
                }
                if kind(current) == .person {
                    peoplePart(current)
                }
                if cardFor(current) != nil {
                    Button {
                        large()
                        withAnimation(Motion.sheet(reduceMotion)) { cardOpen = true }
                    } label: {
                        Label(app: "glossary.onCard", systemImage: "map")
                            .font(.subheadline.weight(.medium))
                    }
                }
                if let allPlaces {
                    Button {
                        allPlaces(current)
                    } label: {
                        Label(app: "glossary.allPlaces", systemImage: "text.magnifyingglass")
                            .font(.subheadline.weight(.medium))
                    }
                }
                if kind(current) == .person, let allPeople {
                    Button(action: allPeople) {
                        Label(app: "glossary.allPeople", systemImage: "person.2")
                            .font(.subheadline.weight(.medium))
                    }
                }
                if let glossary {
                    list(glossary)
                }
            }
            .padding(24)
        }
        // Horizontal and deliberate: vertical dragging belongs to the sheet and the list.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { w in
                let dx = w.translation.width, dy = w.translation.height
                guard abs(dx) > 80, abs(dx) > 2 * abs(dy) else { return }
                swipe(dx < 0)
            }
        )
        .onChange(of: current.id) { revealed = false }
        .background(theme.paperColor)
        .presentationBackground(theme.paperColor)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if kind(current) == .person {
                Monogram(name: current.term)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(appKey: "glossary.type." + kind(current).rawValue)
                        .textCase(.uppercase)
                } icon: {
                    GlossarySheet.glyph(kind(current))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.inkColor.opacity(0.6))
                Text(verbatim: current.term)
                    .font(Typography.title(.title))
                    .foregroundStyle(theme.inkColor)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    static func glyph(_ type: Glossary.Variant) -> Image {
        switch type {
        case .person: Image(systemName: "person")
        case .place: Image(systemName: "mappin.and.ellipse")
        case .cluster: Image(systemName: "person.3")
        case .thing: Image(systemName: "cube")
        case .term: Image(systemName: "text.book.closed")
        case .language: Image(systemName: "character.bubble")
        case .time: Image(systemName: "calendar")
        }
    }

    /// "First in The Guild - up to here 19 times" - `nil` while the index counts.
    private func statusLine(_ e: Glossary.Item) -> String? {
        guard let terms else { return nil }
        let state = terms.state(e.id, until: wordHere)
        guard let first = state.first, let chapter = chapterName(first) else { return nil }
        return Wording.phrase("glossary.state", chapter, state.count)
    }

    // MARK: - Person card

    /// Relations as chips (only explicitly named ones, target already mentioned) and the
    /// timeline in 40 bars up to the current position.
    @ViewBuilder
    private func peoplePart(_ e: Glossary.Item) -> some View {
        let relations = (glossary?.relations(e) ?? []).filter { b in
            guard let terms, let wordHere else { return true }
            return terms.known(b.target.id, until: wordHere)
        }
        if !relations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(relations, id: \.target.id) { b in
                        Button {
                            withAnimation(Motion.soft(reduceMotion)) { chosen = b.target }
                        } label: {
                            Text(
                                verbatim: b.word.isEmpty
                                    ? b.target.term : b.word.capitalized + " · " + b.target.term
                            )
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.inkColor.opacity(0.08), in: Capsule())
                            .foregroundStyle(theme.inkColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if let terms {
            let figures = terms.history(e.id, until: wordHere)
            let highest = max(figures.max() ?? 0, 1)
            if figures.contains(where: { $0 > 0 }) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(figures.indices, id: \.self) { i in
                        Capsule()
                            .fill(theme.inkColor.opacity(figures[i] > 0 ? 0.5 : 0.1))
                            .frame(height: 3 + 21 * CGFloat(figures[i]) / CGFloat(highest))
                    }
                }
                .frame(height: 24, alignment: .bottom)
                .accessibilityElement()
                .accessibilityLabel(Text(app: "glossary.history"))
            }
        }
    }

    // MARK: - All terms

    @ViewBuilder
    private func list(_ glossary: Glossary) -> some View {
        Button {
            if !all { large() }
            withAnimation(Motion.soft(reduceMotion)) { all.toggle() }
        } label: {
            Label {
                Text(verbatim: glossary.heading)
            } icon: {
                Image(systemName: all ? "chevron.down" : "chevron.right")
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(.top, 8)
        if all {
            TextField(text: $search) {
                Text(app: "book.search")
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            let visible = matching(glossary)
            ForEach(visible) { e in
                Button {
                    withAnimation(Motion.soft(reduceMotion)) { chosen = e }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: e.term)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.inkColor)
                        Text(verbatim: e.explanation)
                            .font(.footnote)
                            .foregroundStyle(theme.inkColor.opacity(0.7))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if protected(glossary) {
                Label {
                    Text(app: "glossary.onlyUntilHere")
                } icon: {
                    Image(systemName: "eye.slash")
                }
                .font(.footnote)
                .foregroundStyle(theme.inkColor.opacity(0.6))
                .padding(.top, 6)
            }
        }
    }

    /// Spoiler protection: only what appeared up to the current position - while the index
    /// counts or the position is unknown, everything.
    private func known(_ e: Glossary.Item) -> Bool {
        guard let terms, let wordHere else { return true }
        return terms.known(e.id, until: wordHere) || e.id == entry.id
    }

    private func protected(_ glossary: Glossary) -> Bool {
        glossary.entries.contains { !known($0) }
    }

    private func matching(_ glossary: Glossary) -> [Glossary.Item] {
        let s = search.trimmingCharacters(in: .whitespaces)
        let protected = glossary.entries.filter(known)
        guard !s.isEmpty else { return protected }
        return protected.filter { $0.term.localizedCaseInsensitiveContains(s) }
    }
}

/// The person card without a portrait: two initials on a stable color derived from the name.
private struct Monogram: View {

    let name: String

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(verbatim: initials.uppercased())
            .font(Typography.title(.title3, weight: .semibold))
            .foregroundStyle(Color(red: 0.98, green: 0.97, blue: 0.95))
            .frame(width: 56, height: 56)
            .background(TitlePlaceholder.audio(name).color, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The book's map with a pin on the place: it zooms to the place,
/// the pin drops with a bounce; two fingers zoom further. Without a label no
/// pin, but the honest sentence below. "Reduce Motion": the pin stands at once.
private struct CardView: View {

    let card: BookCard
    let frame: CGRect?
    let name: String
    let theme: ReadingStyle.ReadingTheme
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: CGImage?
    @State private var zoom = CardZoom()
    /// The state at the start of a gesture - pinching and dragging compute from it.
    @State private var pinchStart: CardZoom?
    /// State and finger travel when (re)starting a drag - after a pinch the
    /// gesture keeps counting its travel from first contact; without a zero point the map would jump.
    @State private var dragStart: (zoom: CardZoom, route: CGSize)?
    @State private var size: CGSize = .zero
    @State private var pin = false
    @State private var quarter = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: name)
                    .font(Typography.title(.title3))
                    .foregroundStyle(theme.inkColor)
                Spacer()
                CardRotateButton(quarter: $quarter)
                Button(action: done) {
                    Text(app: "action.done")
                }
            }
            if let image {
                RotatedCard(
                    image: image, pins: frame.map { [name: $0] } ?? [:], quarter: quarter,
                    scale: zoom.scale, offset: zoom.offset,
                    pinFont: .title.weight(.semibold), pinsShown: pin
                )
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { new in
                    size = new
                    // New size (rotation, other detent): the visible part stays within the edge.
                    zoom.offset = CardZoom.limited(zoom.offset, scale: zoom.scale, size: new)
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStart ?? zoom
                            pinchStart = start
                            dragStart = nil
                            let finger = CGSize(
                                width: value.startLocation.x - size.width / 2,
                                height: value.startLocation.y - size.height / 2)
                            zoom = .pinched(
                                start, factor: value.magnification, finger: finger, size: size)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                // Drag only once zoomed - otherwise the drag belongs to the sheet.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            // While pinching the gesture also delivers drags - then it belongs to the pinch.
                            guard pinchStart == nil else { return }
                            let start = dragStart ?? (zoom, value.translation)
                            dragStart = start
                            zoom = .dragged(
                                start.zoom,
                                around: CGSize(
                                    width: value.translation.width - start.route.width,
                                    height: value.translation.height - start.route.height),
                                size: size)
                        }
                        .onEnded { _ in dragStart = nil },
                    isEnabled: zoom.scale > 1
                )
                .onChange(of: quarter) {
                    withAnimation(Motion.sheet(reduceMotion)) { zoom = zoom.rotated(size: size) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: name))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            if frame == nil {
                Text(app: "glossary.notOnCard")
                    .font(.footnote)
                    .foregroundStyle(theme.inkColor.opacity(0.6))
            }
        }
        .padding(24)
        .background(theme.paperColor)
        .task {
            // Fit the image off the main thread - 2048 px take noticeable time.
            let data = card.data
            image = await Task.detached { CardFinder.image(data) }.value
            guard frame != nil else { return }
            // Only once the map knows its size - otherwise the edge clamps the offset to
            // zero and it zooms to the center instead of the place.
            for _ in 0..<30 where size == .zero { try? await Task.sleep(for: .milliseconds(16)) }
            // Reduce motion: no zoom-in, the pin only fades in.
            if !reduceMotion, let frame {
                withAnimation(Motion.zoom(reduceMotion)) {
                    zoom = .on(
                        CGPoint(x: frame.midX, y: frame.midY), scale: 1.8, quarter: quarter,
                        size: size)
                }
            }
            withAnimation(Motion.bounce(reduceMotion).delay(reduceMotion ? 0 : 0.35)) { pin = true }
        }
    }
}
