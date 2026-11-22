import SwiftUI

/// The primary button: accent surface with 14 pt corners (before 8) - no capsule; that is the
/// vocabulary of a rejected style and competes on iOS 26 with the
/// glass bar -, text in ``ColorTheme/buttonText`` - in light
/// white, in dark paper. `.borderedProminent` always colors the label white, and on the
/// light dark-mode accent (ink `#8FC7AE`) that is 1.9 : 1.
/// 44 pt tap target, presses in slightly.
public struct PrimaryButton: ButtonStyle {

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var active

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.buttonText.color)
            .padding(.horizontal, 20)
            .frame(minHeight: TapTarget.atLeast)
            .background(
                theme.accent.color.opacity(active ? 1 : 0.5),
                in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }
}

extension ButtonStyle where Self == PrimaryButton {
    public static var primary: PrimaryButton { PrimaryButton() }
}

/// The chip in the action row of a detail - Saved, Read, Keep: 6 pt corners
/// with hairline in `line`, word in ink, glyph in accent; filled when
/// set. That way the row has one color less and does not read as three
/// more buttons under the primary button. Meant as the label of a `Menu` or `Button`;
/// the style comes from here so three chips side by side weigh the same.
public struct Chip: View {

    private let text: Text
    private let glyph: String
    private let active: Bool

    /// - Parameter glyph: the SF Symbol; when set the `.fill` variant is shown.
    public init(_ text: Text, glyph: String, active: Bool = false) {
        self.text = text
        self.glyph = glyph
        self.active = active
    }

    @Environment(\.theme) private var theme

    public var body: some View {
        let form = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Label {
            text.foregroundStyle(active ? theme.buttonText.color : ColorTheme.typography.color)
        } icon: {
            Image(systemName: active ? glyph + ".fill" : glyph)
                .foregroundStyle(active ? theme.buttonText.color : theme.accent.color)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(active ? theme.accent.color : .clear, in: form)
        .overlay { form.strokeBorder(theme.hairline.color, lineWidth: active ? 0 : 1) }
        .contentShape(form)
    }
}

/// The secondary button beside the primary: same shape and
/// height, the accent as text and as a light surface (12 %) - recognizably second choice,
/// but not a mere link.
public struct SecondaryButton: ButtonStyle {

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var active

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(theme.accent.color.opacity(active ? 1 : 0.5))
            .padding(.horizontal, 20)
            .frame(minHeight: TapTarget.atLeast)
            .background(
                theme.accent.color.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }
}

extension ButtonStyle where Self == SecondaryButton {
    public static var secondary: SecondaryButton { SecondaryButton() }
}
