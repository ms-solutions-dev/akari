import SwiftUI

/// The library segment: All, Manga, Books, Audiobooks - a round surface, the choice as a
/// pill on it (light: paper with shadow, dark: raised), text instead of accent, no stroke.
/// Every field is 44 pt high. From accessibility sizes the fields stack - four words
/// side by side otherwise break by syllable.
///
/// With podcasts there are five fields, and on iPhone "Audiobooks" broke to
/// "Audio-books"; a smaller font was "too
/// tight". Hence from five fields in compact width: each field as wide as
/// its word, the bar scrolls sideways, and the choice is scrolled into view - like
/// the filter bar in Apple Podcasts. Up to four fields and on iPad it stays the
/// evenly divided pill.
public struct Segment<Value: Hashable>: View {

    private let selection: Binding<Value>
    private let fields: [(value: Value, name: Text)]

    public init(selection: Binding<Value>, fields: [(value: Value, name: Text)]) {
        self.selection = selection
        self.fields = fields
    }

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var schema
    @Environment(\.accessibilityReduceMotion) private var calm
    @Environment(\.dynamicTypeSize) private var typeSize
    @Namespace private var pill

    @Environment(\.horizontalSizeClass) private var width

    /// Width of the soft edge when the bar scrolls.
    private static var margin: CGFloat { 24 }

    /// Scrolling instead of divided: five or more fields in compact width.
    private var rolling: Bool {
        fields.count >= 5 && width != .regular && !typeSize.isAccessibilitySize
    }

    public var body: some View {
        if rolling {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    bar(shared: false)
                }
                // At rest the bar sits entirely inside the soft edge: "All"
                // on the left is fully visible, the gradient only lies over further content.
                .contentMargins(.horizontal, Segment.margin, for: .scrollContent)
                .scrollClipDisabled()
                .onAppear { reader.scrollTo(selection.wrappedValue, anchor: .center) }
                .onChange(of: selection.wrappedValue) { _, new in
                    withAnimation(Motion.short(calm)) { reader.scrollTo(new, anchor: .center) }
                }
            }
            // Soft edges as a scroll hint: a half-visible "All" on the left
            // and "Podcasts" on the right looked cut off instead of scrollable. The margin above
            // and below keeps the pill's shadow out of the mask.
            .padding(.vertical, 8)
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Segment.margin)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Segment.margin)
                }
            }
            .padding(.vertical, -8)
        } else {
            bar(shared: true)
        }
    }

    /// The pill itself. `divided` distributes the width evenly over the fields;
    /// otherwise each field takes the width of its word.
    private func bar(shared: Bool) -> some View {
        let arrangement =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return arrangement {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                let chosen = field.value == selection.wrappedValue
                Button {
                    Haptics.selection()
                    withAnimation(Motion.short(calm)) { selection.wrappedValue = field.value }
                } label: {
                    field.name
                        .font(.subheadline.weight(chosen ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: !shared, vertical: false)
                        .foregroundStyle(chosen ? ColorTheme.typography.color : ColorTheme.muted.color)
                        .frame(maxWidth: shared ? .infinity : nil, minHeight: 40)
                        .padding(.horizontal, shared ? 4 : 14)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(schema == .dark ? Color.white.opacity(0.10) : theme.paper.color)
                                    .shadow(
                                        color: .black.opacity(schema == .dark ? 0 : 0.10), radius: 6, y: 2
                                    )
                                    .matchedGeometryEffect(id: "pille", in: pill)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
                .id(field.value)
            }
        }
        .padding(3)
        .background(theme.surface.color, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .frame(minHeight: 44)
    }
}
