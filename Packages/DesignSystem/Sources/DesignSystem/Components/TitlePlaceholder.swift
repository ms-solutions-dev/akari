import SwiftUI

/// A cover for a book without a cover: title and author in Newsreader on a surface
/// whose color comes from the title.
///
/// For own EPUBs and OPDS catalogs without an image the placeholder is the most common
/// sight - a gray box with a glyph looked like "image missing". The color is
/// stable: the same book has the same one on every device and after every start, because it comes from
/// a fixed hash of the letters, not from `hashValue` (which is shuffled anew per start).
/// The eight tones are muted like linen, so a shelf full of placeholders
/// stays calm; text is paper on every tone (>= 4.5 : 1 computed for the base tones).
public struct TitlePlaceholder: View {

    private let title: String
    private let author: String?

    public init(title: String, author: String? = nil) {
        self.title = title
        self.author = author
    }

    public var body: some View {
        GeometryReader { space in
            let margin = max(6, space.size.width * 0.09)
            ZStack(alignment: .topLeading) {
                TitlePlaceholder.audio(title).color
                // Spine edge: a darker strip on the left, like a bound book.
                Rectangle()
                    .fill(.black.opacity(0.18))
                    .frame(width: max(2, space.size.width * 0.035))
                // Below 56 pt (genre card) text would only be noise: then tone and spine.
                if space.size.width >= 56 {
                    VStack(alignment: .leading, spacing: margin * 0.6) {
                        if let author, !author.isEmpty {
                            Text(verbatim: author.uppercased())
                                .font(.system(size: max(7, space.size.width * 0.075), weight: .medium))
                                .tracking(0.6)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .opacity(0.8)
                        }
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(.white.opacity(0.35))
                            .frame(width: space.size.width * 0.25, height: 1)
                        Text(verbatim: title)
                            .font(Typography.title(.headline, weight: .semibold))
                            .lineLimit(5)
                            .minimumScaleFactor(0.45)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color(red: 0.98, green: 0.97, blue: 0.95))
                    .padding(margin)
                    .padding(.leading, space.size.width * 0.03)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [title, author].compactMap { $0 }.joined(separator: ", ")))
    }

    /// Eight linen tones, the same in light and dark - a cover is an object, not a theme.
    static let tones: [AdaptiveColor] = [
        AdaptiveColor(0x2F5D50),  // fir green
        AdaptiveColor(0x7A3E2E),  // brick
        AdaptiveColor(0x34466E),  // ink blue
        AdaptiveColor(0x6B4A6E),  // plum
        AdaptiveColor(0x5C5A2E),  // olive
        AdaptiveColor(0x8A5A2B),  // ochre
        AdaptiveColor(0x3E5566),  // slate
        AdaptiveColor(0x6E3B47),  // wine red
    ]

    /// The tone for a title - FNV-1a over the Unicode scalars, stable across starts and devices.
    public static func audio(_ title: String) -> AdaptiveColor {
        var h: UInt32 = 2_166_136_261
        for s in title.lowercased().unicodeScalars {
            h ^= s.value
            h = h &* 16_777_619
        }
        return tones[Int(h % UInt32(tones.count))]
    }
}
