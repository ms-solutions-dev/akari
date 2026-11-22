import DesignSystem
import Library
import SwiftUI

/// The header above the grid: title, the two pills **Sort** and **Filter**, the counter, and
/// with an active filter a row of chips. It sticks to the top while scrolling.
///
/// **One place to filter.** Filtering used to be the third entry in a menu behind a
/// sort icon, and nobody found it. The pills are labeled; the sort pill shows its value
/// ("New"), the filter pill the number of criteria. The filter state is never invisible:
/// pill, counter "418 of 37,214" and chips.
struct GridHeader: View {

    /// "All books" without a filter, "Books" with one; `nil` on pages with their own title.
    let title: Text?
    /// "37,214 books" or "418 of 37,214 books".
    let counter: String?
    @Binding var sorting: Sorting
    let sortings: [Sorting]
    /// Reading lists have their own order, so a hint replaces the pill.
    var sortingLocked = false
    @Binding var filtering: Filtering
    var names = FilterNames()
    let showFilters: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var fontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fontSize.isAccessibilitySize {
                if let title { titleRow(title) }
                HStack(spacing: 8) { pills }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    if let title { titleRow(title) }
                    Spacer(minLength: 8)
                    pills
                }
            }
            if let counter {
                Text(verbatim: counter)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
            }
            if !filtering.empty {
                FilterChips(filtering: $filtering, withEdge: false, names: names)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.paper.color)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func titleRow(_ title: Text) -> some View {
        title
            .font(Typography.title(.title2, weight: .semibold))
            .foregroundStyle(ColorTheme.typography.color)
            .accessibilityAddTraits(.isHeader)
            .lineLimit(2)
    }

    @ViewBuilder
    private var pills: some View {
        if sortingLocked {
            EmptyView()
        } else {
            Menu {
                Picker(selection: $sorting) {
                    ForEach(sortings, id: \.self) { s in
                        Text(appKey: s.lookupKey).tag(s)
                    }
                } label: {
                    Text(app: "sorting.title")
                }
                .pickerStyle(.inline)
            } label: {
                Pill(
                    glyph: "arrow.up.arrow.down", text: Text(appKey: sorting.shortKey),
                    active: false)
            }
            .accessibilityLabel(
                Text("\(Text(app: "sorting.title")), \(Text(appKey: sorting.lookupKey))")
            )
            .accessibilityHint(Text(app: "sorting.pill.hint"))
        }
        Button(action: showFilters) {
            Pill(
                glyph: "line.3.horizontal.decrease.circle" + (filtering.empty ? "" : ".fill"),
                text: filtering.empty
                    ? Text(app: "filter.title")
                    : Text(verbatim: Phrase.from("filter.pill.count", filtering.count)),
                active: !filtering.empty)
        }
        .buttonStyle(.plain)
        // For VoiceOver: "Filter, 2 active"; color alone does not convey it.
        .accessibilityLabel(Text(app: "filter.title"))
        .accessibilityValue(
            filtering.empty
                ? Text(verbatim: "") : Text(verbatim: Phrase.from("filter.pill.count", filtering.count))
        )
        .accessibilityHint(Text(app: "filter.pill.hint"))
    }
}

/// A labeled pill in the grid header: at least 36 pt tall, text 15 pt; when active filled in the
/// accent color.
private struct Pill: View {
    let glyph: String
    let text: Text
    let active: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
            text
        }
        .font(.subheadline.weight(active ? .semibold : .medium))
        .foregroundStyle(active ? theme.buttonText.color : ColorTheme.typography.color)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background {
            Capsule().fill(active ? theme.accent.color : theme.raised.color)
        }
        .overlay {
            if !active { Capsule().strokeBorder(theme.hairline.color, lineWidth: 1) }
        }
        .contentShape(Capsule())
    }
}

extension Sorting {
    /// The short word in the sort pill: "New", "Title", "Stars".
    var shortKey: String { "sorting.short." + rawValue }
}

extension Filtering {
    /// "37,214 books" without a filter, "418 of 37,214 books" with one, numbers formatted.
    static func counter(hit: Int, total: Int, unitLabel: (Int) -> String) -> String {
        hit == total
            ? unitLabel(total)
            : Phrase.from("filter.counter.from", Formats.integer(hit), unitLabel(total))
    }
}

/// "Apply as filter" in the context menu of a genre or shelf card: the
/// card above the grid puts its genre or shelf into the grid's filter instead of opening its own
/// page. The ``ShelfView`` sets the request for its header; elsewhere it is absent,
/// and so is the menu entry.
enum FilterRequest: Hashable {
    case genre(String)
    case shelf(String)
}

/// The acceptance of a ``FilterRequest``: always compares equal, so the environment does not redraw
/// its readers on every pass; it reads the filter only when called.
struct FilterRequestAcceptance: Equatable {
    let take: (FilterRequest) -> Void
    static func == (_: Self, _: Self) -> Bool { true }
    func callAsFunction(_ w: FilterRequest) { take(w) }
}

extension EnvironmentValues {
    @Entry var filterRequest: FilterRequestAcceptance? = nil
}

/// The context menu with "Apply as filter", only where a grid accepts the request; otherwise
/// the card stays without a menu (an empty menu would still show the preview).
private struct AsFilterMenu: ViewModifier {
    let request: FilterRequest?
    @Environment(\.filterRequest) private var apply

    func body(content: Content) -> some View {
        if let request, let apply {
            content.contextMenu {
                Button {
                    apply(request)
                } label: {
                    Label {
                        Text(app: "filter.asFilter")
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func asFilterMenu(_ request: FilterRequest?) -> some View { modifier(AsFilterMenu(request: request)) }
}
