import SwiftUI

/// The badge: no cushion, no color in the background - a
/// letter-spaced word in accent or secondary tone. "NEW", "KEPT", "VOLUME 8".
///
/// On a cover it needs a ground, otherwise it vanishes into the image: there
/// ``Tile`` puts a paper cushion beneath it, the badge itself stays the same.
public struct Badge: View {

    public enum Audio: Sendable {
        case accent, muted
    }

    private let text: Text
    private let audio: Audio

    public init(_ text: Text, audio: Audio = .accent) {
        self.text = text
        self.audio = audio
    }

    public init(_ lookupKey: LocalizedStringKey, audio: Audio = .accent) {
        self.init(Text(app: lookupKey), audio: audio)
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        text
            .font(Typography.badge)
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(audio == .accent ? theme.accent.color : ColorTheme.muted.color)
            .lineLimit(1)
    }
}
