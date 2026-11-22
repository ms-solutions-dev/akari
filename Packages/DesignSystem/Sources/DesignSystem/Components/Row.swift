import SwiftUI

/// The row in a list - volume list from 30 volumes, search hits, saved: on the left
/// an index in a hairline box or a small cover, then name in
/// serif and secondary line, on the right the badge. The current row carries the name
/// semibold. Tap target 44 pt, even with one line of text.
public struct Row<Leading: View>: View {

    private let name: Text
    private let secondaryLine: Text?
    private let badge: Text?
    private let ongoing: Bool
    /// The kept mark on the right - `arrow.down.circle.fill` when the title is on
    /// the device; nothing for "not kept".
    private let character: String?
    private let characterName: Text?
    private let front: Leading

    public init(
        name: Text, secondaryLine: Text? = nil, badge: Text? = nil, ongoing: Bool = false,
        character: String? = nil,
        characterName: Text? = nil,
        @ViewBuilder front: () -> Leading
    ) {
        self.name = name
        self.secondaryLine = secondaryLine
        self.badge = badge
        self.ongoing = ongoing
        self.character = character
        self.characterName = characterName
        self.front = front()
    }

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        // From accessibility sizes nothing fits beside the name anymore: the
        // badge slips under the secondary line instead of truncating the name to "Man...".
        let large = typeSize.isAccessibilitySize
        HStack(alignment: large ? .top : .center, spacing: 12) {
            front
            VStack(alignment: .leading, spacing: 2) {
                name
                    .font(Typography.name(.body))
                    .fontWeight(ongoing ? .semibold : .medium)
                    .foregroundStyle(ColorTheme.typography.color)
                    .lineLimit(2)
                if let secondaryLine {
                    secondaryLine
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(ColorTheme.muted.color)
                        // At AX3 "Volume 47 - p. 63/205" does not fit in one line -
                        // then three lines instead of "Volume 47 - 1...".
                        .lineLimit(large ? 3 : 1)
                }
                if large, let badge {
                    Badge(badge)
                }
            }
            Spacer(minLength: 8)
            if !large, let badge {
                Badge(badge)
            }
            if let character {
                Image(systemName: character)
                    .font(.footnote)
                    .foregroundStyle(theme.accent.color)
                    .accessibilityLabel(characterName ?? Text(verbatim: ""))
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension Row where Leading == RowIndex {
    /// A row with an index instead of a cover - "13" in the box.
    public init(
        index: String, name: Text, secondaryLine: Text? = nil, badge: Text? = nil, ongoing: Bool = false
    ) {
        self.init(name: name, secondaryLine: secondaryLine, badge: badge, ongoing: ongoing) {
            RowIndex(index)
        }
    }
}

/// The box with the number: hairline, corners 3 pt, serif 13 pt, fixed digits.
public struct RowIndex: View {

    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        Text(verbatim: text)
            .font(Typography.name(.footnote))
            .monospacedDigit()
            .foregroundStyle(ColorTheme.typography.color)
            .frame(minWidth: 30, minHeight: 30)
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(theme.hairline.color, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
