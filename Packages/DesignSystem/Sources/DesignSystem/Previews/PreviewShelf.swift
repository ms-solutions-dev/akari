import SwiftUI

/// What the previews need: invented covers in the colors of the design and
/// a frame that shows every building block in all four themes and both brightnesses.
/// Only for `#Preview` - none of it appears in the app build.
enum PreviewShelf {

    /// A cover without a server: a surface with a spine color and title.
    struct Cover: View {
        let color: UInt32
        let title: String

        var body: some View {
            ZStack(alignment: .bottomLeading) {
                Color(hex: color)
                Text(verbatim: title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(6)
            }
        }
    }

    static let islandSaga = Cover(color: 0x2F6F5E, title: "Island Saga 47")
    static let glassOrchard = Cover(color: 0x3B5B8C, title: "The Glass Orchard")
    static let lastSignal = Cover(color: 0x8E5A34, title: "The Last Signal")
    static let northSaga = Cover(color: 0xA9482B, title: "Northern Saga 8")

    /// Four times light, four times dark - the building block in every theme.
    struct AllThemes<Content: View>: View {
        @ViewBuilder let content: () -> Content

        var body: some View {
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(ColorTheme.allCases) { theme in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: theme.rawValue).font(.caption).foregroundStyle(.secondary)
                            content()
                        }
                        .padding()
                        .theme(theme)
                    }
                }
            }
        }
    }
}
