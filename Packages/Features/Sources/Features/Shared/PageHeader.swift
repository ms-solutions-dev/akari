import DesignSystem
import SwiftUI

/// The tab header row: the brand (Start) or the title (Library) on the left,
/// the glass circles (menu, account) on the right at 44 pt, all on one center line. A
/// building block instead of the system bar, so Start and Library have the same height;
/// the system bar stays with the sheets behind, where the back button sits.
struct PageHeader<Leading: View, Trailing: View>: View {

    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading
            Spacer(minLength: 0)
            HStack(spacing: 10) { trailing }
        }
        .frame(height: 44)
        .padding(.horizontal)
        // The row is 44 pt like a bar; its circles and the title grow up to
        // xxxLarge, not to AX3, where the circles ran into each other and "Library"
        // was truncated. The content below keeps growing.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// The page title in the header row, as large as the brand beside it would be.
struct PageTitle: View {

    let text: Text

    var body: some View {
        text
            .font(Typography.title(.title))
            .foregroundStyle(ColorTheme.typography.color)
            .lineLimit(1)
            .offset(y: 1)
    }
}

extension View {
    /// The name sits in the sheet's header; it only goes into the bar once the header
    /// below has scrolled away, otherwise it appears twice, one above the other. One modifier
    /// for both series and author pages so they do not drift apart.
    func titleOnScroll(_ title: Text) -> some View {
        modifier(TitleOnScroll(title: title))
    }

    /// The system's round glass, as around a bar button in iOS 26, at 44 pt.
    func glassCircle() -> some View {
        frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }

    /// Hides the navigation bar, on iOS only; on the Mac (where `swift test`
    /// runs) the bar does not exist as a target.
    func withoutBar(_ from: Bool = true) -> some View {
        #if os(iOS)
            return toolbarVisibility(from ? .hidden : .automatic, for: .navigationBar)
        #else
            return self
        #endif
    }
}

private struct TitleOnScroll: ViewModifier {
    /// "Reduce Motion": then no animation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: Text
    @State private var flattened = false

    func body(content: Content) -> some View {
        content
            .navigationTitle(flattened ? title : Text(verbatim: ""))
            .toolbarTitleDisplayMode(.inline)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 140
            } action: { _, new in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { flattened = new }
            }
    }
}
