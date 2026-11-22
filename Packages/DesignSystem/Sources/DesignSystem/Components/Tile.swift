import SwiftUI

/// The tile in the grid and in the rows of the start page: the framed cover (the
/// frame is brought by the caller - ``CoverFrame``), below it the name in serif
/// and a secondary line with fixed digits. The kind badge stands **before the
/// secondary line** ("Manga - Volume 1 - p. 8/227"), not on the image: no cushion
/// on the cover, text never on the image. At the bottom
/// right of the cover stays the place of the kept mark (`mark`; filled by the store).
/// A progress, if there is one, as a strip
/// **in the bottom edge of the cover** (like Apple TV), not between image and name.
///
/// The width is given by the caller (grid, row); the height follows the cover.
public struct Tile<Cover: View, Mark: View>: View {

    private let name: Text
    private let secondaryLine: Text?
    private let badge: Text?
    private let progress: Double?
    private let cover: Cover
    private let character: Mark

    /// - Parameter mark: what stands at the bottom right of the cover - the
    ///   kept badge or the ring while fetching; otherwise nothing.
    public init(
        name: Text, secondaryLine: Text? = nil, badge: Text? = nil, progress: Double? = nil,
        @ViewBuilder cover: () -> Cover, @ViewBuilder character: () -> Mark
    ) {
        self.name = name
        self.secondaryLine = secondaryLine
        self.badge = badge
        self.progress = progress
        self.cover = cover()
        self.character = character()
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            cover
                .overlay(alignment: .bottom) {
                    if let progress {
                        CoverStrip(fraction: progress)
                    }
                }
                .overlay(alignment: .bottomTrailing) { character.padding(4) }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .environment(\.coverShadowOff, true)
            VStack(alignment: .leading, spacing: 2) {
                name
                    .font(Typography.name(.footnote))
                    .foregroundStyle(ColorTheme.typography.color)
                    .lineLimit(2)
                // Badge and secondary line as **one** text so the line may wrap:
                // "MANGA - 14 vol..." at 110 pt says nothing, two lines say everything.
                if let line = Tile.line(badge, secondaryLine) {
                    line
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(ColorTheme.muted.color)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        // The strip is mute - the state as a value: "Pepper&Carrot 37, volume 37, 40 %".
        .accessibilityValue(
            progress.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(verbatim: "")
        )
    }
}

extension Tile {
    /// "MANGA - Volume 1 - p. 8/227" - the badge letter-spaced and semibold, the rest
    /// like a secondary line; `Text` can be composed, an `HStack` cannot wrap.
    static func line(_ badge: Text?, _ secondaryLine: Text?) -> Text? {
        let trackedBadge = badge.map { $0.font(Typography.badge).tracking(1.2) }
        switch (trackedBadge, secondaryLine) {
        case (let a?, let n?): return Text("\(a) · \(n)")
        case (let a?, nil): return a
        case (nil, let n?): return n
        default: return nil
        }
    }
}

extension Tile where Mark == EmptyView {
    public init(
        name: Text, secondaryLine: Text? = nil, badge: Text? = nil, progress: Double? = nil,
        @ViewBuilder cover: () -> Cover
    ) {
        self.init(
            name: name, secondaryLine: secondaryLine, badge: badge, progress: progress, cover: cover
        ) {
            EmptyView()
        }
    }
}

/// The progress in the bottom edge of a cover: three points of accent on a
/// darkened track so it is visible on any image; under two percent
/// at least six points so "started" is not a dot.
public struct CoverStrip: View {

    private let fraction: Double

    public init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        GeometryReader { mass in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.35)
                theme.accent.color.frame(width: max(mass.size.width * fraction, fraction > 0 ? 6 : 0))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
