import SwiftUI

/// Progress as a bar, three points high, accent on hairline - and beside
/// or below it the text ("Page 63 of 205", "62 %") with fixed digits. No
/// ring: a ring says "percent", a bar says "distance", and what is read is a
/// distance.
public struct ProgressBar: View {

    private let fraction: Double
    private let text: Text?

    /// - Parameter fraction: 0 to 1; anything above and below is clipped.
    public init(fraction: Double, text: Text? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        self.text = text
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { mass in
                // Track in a muted tone instead of the hairline: 1.4 : 1 was not visible,
                // so it was not visible that it is a bar.
                // Under two percent at least six points - "started" is not a dot.
                ZStack(alignment: .leading) {
                    Capsule().fill(ColorTheme.muted.color.opacity(0.35))
                    Capsule().fill(theme.accent.color)
                        .frame(width: max(mass.size.width * fraction, fraction > 0 ? 6 : 0))
                }
            }
            .frame(height: 3)
            if let text {
                text
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}
