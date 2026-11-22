import SwiftUI

/// The frame around every cover: aspect ratio 2 : 3 - for audiobooks 1 : 1, because
/// their covers are square, and a square in portrait with bars looks
/// like "image missing" -, a half-point ring - dark in light,
/// light in dark - and below it the surface as a placeholder while no image
/// is there. What counts as an image is the caller's decision; the frame knows nothing of servers.
///
/// Covers are objects: corners 4 pt, a fine sheen on the
/// spine edge and a two-stage shadow (contact + room), stronger in the dark so
/// it is visible on `#1A1B1A` at all. Small covers in lists carry only the
/// contact shadow - a room shadow of 14 pt makes a 44 pt miniature heavy.
public struct CoverFrame<Content: View>: View {

    public static var aspectRatio: CGFloat { CoverFormat.portrait }

    /// How deep the cover lies above the paper.
    public enum Depth: Sendable {
        /// Contact and room shadow - tiles, hero, detail.
        case normal
        /// Contact shadow only - rows in lists.
        case flat
    }

    private let aspectRatio: CGFloat
    private let depth: Depth
    private let content: Content

    public init(
        aspectRatio: CGFloat = CoverFormat.portrait, depth: Depth = .normal,
        @ViewBuilder content: () -> Content
    ) {
        self.aspectRatio = aspectRatio
        self.depth = depth
        self.content = content()
    }

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var schema
    @Environment(\.coverShadowOff) private var shadowOff

    public var body: some View {
        let dark = schema == .dark
        let form = RoundedRectangle(cornerRadius: Radius.cover, style: .continuous)
        ZStack {
            theme.surface.color
            content
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .overlay(alignment: .leading) {
            // Sheen on the spine: 1 pt white, 18 %.
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1)
        }
        .clipShape(form)
        .overlay {
            form.strokeBorder(
                AdaptiveColor(light: 0x000000, dark: 0xFFFFFF).color.opacity(0.16), lineWidth: 0.5)
        }
        // The shadow on a shape beneath, not on the cover: that way it arises from the
        // outline instead of every image including content being drawn once more for the blur.
        // And **one** shadow instead of two: the room shadow
        // blurred the contact shadow along, two blur passes per tile, on every movement -
        // a grid with twenty covers computed forty. One, somewhat tighter and darker, reads
        // the same.
        .background {
            if shadowOff {
                form.fill(theme.surface.color)
            } else {
                form.fill(theme.surface.color)
                    .modifier(CoverShadow(space: depth == .normal, dark: dark))
            }
        }
    }
}

/// The one shadow of a cover: tiles, hero and detail lie higher (room), rows in
/// lists flat (contact only).
private struct CoverShadow: ViewModifier {
    let space: Bool
    let dark: Bool

    func body(content: Content) -> some View {
        content.shadow(
            color: .black.opacity(space ? (dark ? 0.55 : 0.20) : (dark ? 0.50 : 0.18)),
            radius: space ? 9 : 2, y: space ? 5 : 1)
    }
}

/// The two formats: book and manga portrait 2 : 3, audiobook square.
public enum CoverFormat {
    public static let portrait: CGFloat = 2 / 3
    public static let square: CGFloat = 1
}

/// A cover that has none yet: the surface with a quiet glyph per kind.
public struct CoverPlaceholder: View {

    private let glyph: String

    /// - Parameter glyph: The SF Symbol name - `book.closed` for books,
    ///   `book.pages` for manga, `headphones` for audiobooks.
    public init(glyph: String) {
        self.glyph = glyph
    }

    public var body: some View {
        Image(systemName: glyph)
            .font(.title2)
            .foregroundStyle(ColorTheme.muted.color.opacity(0.5))
    }
}

extension EnvironmentValues {
    /// No shadow under the cover - where a frame above it cuts it off anyway (the
    /// ``Tile`` clips its cover for strips and marks). The blur was computed
    /// regardless, per tile and movement.
    @Entry public var coverShadowOff = false
}
