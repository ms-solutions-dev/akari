import SwiftUI

/// The empty state: an image, a sentence in serif, a sentence in grotesque, at most
/// one button. The image is a slot - an SF Symbol in the secondary tone, or the
/// ``Worm``, where the emptiness may be friendly.
public struct EmptyState<ImageContent: View, ActionContent: View>: View {

    private let title: Text
    private let text: Text?
    private let image: ImageContent
    private let action: ActionContent

    public init(
        title: Text, text: Text? = nil, @ViewBuilder image: () -> ImageContent,
        @ViewBuilder action: () -> ActionContent
    ) {
        self.title = title
        self.text = text
        self.image = image()
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: 12) {
            image
                .frame(minHeight: 78)
                .foregroundStyle(ColorTheme.muted.color)
            title
                .font(Typography.title(.title3))
                .foregroundStyle(ColorTheme.typography.color)
                .multilineTextAlignment(.center)
            if let text {
                text
                    .font(.subheadline)
                    .foregroundStyle(ColorTheme.muted.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            action
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The glyph as an image while the worm is not there.
public struct EmptyGlyph: View {
    private let name: String

    public init(_ name: String) { self.name = name }

    public var body: some View {
        Image(systemName: name).font(.system(size: 44, weight: .light))
    }
}

extension EmptyState where ImageContent == EmptyGlyph, ActionContent == EmptyView {
    public init(glyph: String, title: Text, text: Text? = nil) {
        self.init(title: title, text: text) {
            EmptyGlyph(glyph)
        } action: {
            EmptyView()
        }
    }
}

extension EmptyState where ImageContent == EmptyGlyph {
    public init(
        glyph: String, title: Text, text: Text? = nil, @ViewBuilder action: () -> ActionContent
    ) {
        let button = action()
        self.init(title: title, text: text) {
            EmptyGlyph(glyph)
        } action: {
            button
        }
    }
}
