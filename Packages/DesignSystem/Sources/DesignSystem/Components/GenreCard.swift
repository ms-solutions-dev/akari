import SwiftUI

/// The card in the genre row: three fanned covers, below them the name in serif
/// and the count. Hairline, corners 6 pt, 118 pt wide - no photo, no color:
/// the covers are the picture.
public struct GenreCard<Cover: View>: View {

    private let name: Text
    private let count: Text?
    private let cover: [Cover]

    /// - Parameter cover: up to three cover views, frontmost first.
    public init(name: Text, count: Text? = nil, cover: [Cover]) {
        self.name = name
        self.count = count
        self.cover = Array(cover.prefix(3))
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach(Array(cover.enumerated().reversed()), id: \.offset) { i, image in
                    // Flat: a room shadow of 14 pt on 34 pt covers was heavy - and three per card,
                    // well over thirty blur passes per row.
                    CoverFrame(depth: .flat) { image }
                        .frame(width: 34)
                        .rotationEffect(.degrees(Double(i) * -6))
                        .offset(x: CGFloat(i) * 14, y: CGFloat(i) * -2)
                }
            }
            .frame(width: 86, height: 58, alignment: .leading)
            .padding(.leading, 4)
            // Two lines for "Science Fiction", "Historical Novel"; the card has
            // a fixed height so the row does not jump.
            name
                .font(Typography.name(.subheadline))
                .foregroundStyle(ColorTheme.typography.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let count {
                count
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 118, height: 156, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(theme.hairline.color, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
