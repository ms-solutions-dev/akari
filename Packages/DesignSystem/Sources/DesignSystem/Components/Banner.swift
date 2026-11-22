import SwiftUI

/// The banner at the top of an area: offline, disruption, filter. Corners 6 pt, hairline,
/// paper - no yellow or red surface: a banner says what is, and what to do.
/// Urgency is carried by the glyph and a narrow strip on the left in the
/// signal color of the `level` ("slow" and "sign-in
/// expired" used to look the same).
public struct Banner<ActionsContent: View>: View {

    public enum Kind: Sendable {
        case offline, disruption, filter, hint

        var image: Image {
            switch self {
            case .offline: Image(systemName: "wifi.slash")
            case .disruption: Image(systemName: "exclamationmark.triangle")
            case .filter: Image(systemName: "line.3.horizontal.decrease.circle")
            case .hint: Image(systemName: "info.circle")
            }
        }
    }

    private let kind: Kind
    private let level: ColorTheme.Signal?
    private let text: Text
    private let actions: ActionsContent

    public init(
        _ kind: Kind, level: ColorTheme.Signal? = nil, text: Text, @ViewBuilder actions: () -> ActionsContent
    ) {
        self.kind = kind
        self.level = level
        self.text = text
        self.actions = actions()
    }

    private var glyphColor: Color {
        if let level { return level.color }
        return kind == .disruption ? theme.accent.color : ColorTheme.muted.color
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                text
                    .font(.subheadline)
                    .foregroundStyle(ColorTheme.typography.color)
            } icon: {
                kind.image
                    .foregroundStyle(glyphColor)
            }
            HStack(spacing: 16) {
                actions
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.fill.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(theme.hairline.color, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if let level {
                Rectangle()
                    .fill(level.color)
                    .frame(width: 3)
            }
        }
        // The strip follows the 6 pt rounding instead of sticking out past the corner.
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
    }
}

extension Banner where ActionsContent == EmptyView {
    public init(_ kind: Kind, level: ColorTheme.Signal? = nil, text: Text) {
        self.init(kind, level: level, text: text) { EmptyView() }
    }
}
