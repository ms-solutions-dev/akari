import DesignSystem
import SwiftUI
import UIKit

/// The "Aa" sheet: reading theme, size, typeface, line spacing, margins, justification,
/// hyphenation, publisher style, flow, animation, margin rule, brightness,
/// and "Reset" at the bottom. Every change takes effect immediately
/// behind the sheet so the effect is visible.
struct AaSheet: View {

    @Bindable var style: ReadingStyle
    let adopt: () -> Void
    /// The book's glossary - the toggle only appears in the sheet when there is one.
    var glossary: Glossary? = nil
    var glossaryApply: () -> Void = {}

    @State private var brightness: Double = 0.5
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var width

    enum Marking: String, CaseIterable, Identifiable {
        case sparing = "sparsam", pronounced = "deutlich", from = "aus"
        var id: String { rawValue }
    }

    /// Three levels on two values: `glossary` (line on) and `prominent`.
    private var marking: Binding<Marking> {
        Binding(
            get: { !style.glossary ? .from : style.pronounced ? .pronounced : .sparing },
            set: {
                style.glossary = $0 != .from
                style.pronounced = $0 == .pronounced
                glossaryApply()
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    themeChoice
                    size
                } header: {
                    Text(app: "book.aa")
                }
                Section {
                    Picker(selection: $style.typography) {
                        ForEach(ReadingStyle.TypographyChoice.allCases) { choice in
                            Text(verbatim: choice.name).tag(choice)
                        }
                    } label: {
                        Text(app: "book.typeface")
                    }
                    slider(
                        "book.lineSpacing", value: $style.lineSpacing,
                        area: ReadingStyle.lineSpacingRange,
                        step: 0.1, glyph: "text.line.first.and.arrowtriangle.forward", publisherStyle: true
                    )
                    slider(
                        "book.margins", value: $style.margins, area: ReadingStyle.marginRange, step: 0.25,
                        glyph: "rectangle.inset.filled", publisherStyle: false)
                    Toggle(isOn: switchBinding($style.justified, publisherStyle: true)) {
                        Label(app: "book.justified", systemImage: "text.justify")
                    }
                    Toggle(isOn: switchBinding($style.hyphenation, publisherStyle: true)) {
                        Label(app: "book.hyphenation", systemImage: "text.word.spacing")
                    }
                    Toggle(isOn: $style.publisherStyle) {
                        Label(app: "book.publisherStyle", systemImage: "book.closed")
                    }
                } footer: {
                    Text(app: "book.publisherStyle.hint")
                }
                // Columns exist only on iPad (wide size class): on iPhone Readium decides itself,
                // and a slider that does nothing is a trap.
                if width == .regular {
                    Section {
                        Picker(selection: $style.columns) {
                            ForEach(ReadingStyle.ColumnChoice.allCases) { choice in
                                Text(app: "book.columns.\(choice.rawValue)").tag(choice)
                            }
                        } label: {
                            Label(app: "book.columns", systemImage: "rectangle.split.2x1")
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text(app: "book.columns.hinweis")
                    }
                }
                Section {
                    Toggle(isOn: $style.reflowing) {
                        Label(app: "book.reflowing", systemImage: "arrow.up.and.down.text.horizontal")
                    }
                    Toggle(isOn: $style.animation) {
                        Label(app: "book.animation", systemImage: "arrow.left.and.right")
                    }
                    Toggle(isOn: $style.bothMarginsForward) {
                        Label(app: "book.bothMargins", systemImage: "arrow.right.to.line")
                    }
                }
                if let glossary {
                    Section {
                        // Marking: Sparse, Prominent or Off; tapping is separate from it.
                        Picker(selection: marking) {
                            ForEach(Marking.allCases) { m in
                                Text(appKey: "book.mark." + m.rawValue).tag(m)
                            }
                        } label: {
                            Label(app: "book.glossary", systemImage: "character.book.closed")
                        }
                        Toggle(isOn: $style.tap) {
                            Label(app: "book.tap", systemImage: "hand.tap")
                        }
                        Toggle(isOn: $style.edgeTurning) {
                            Label(app: "book.edgeTurning", systemImage: "arrow.left.and.right")
                        }
                        Toggle(isOn: $style.explanationAfterTap) {
                            Label(app: "book.explanationAfterTap", systemImage: "eye.slash")
                        }
                    } footer: {
                        Text(
                            verbatim: String(
                                format: String(localized: "book.glossary.hint", bundle: .main),
                                locale: .current, glossary.entries.count, glossary.heading))
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "sun.min")
                        Slider(value: $brightness, in: 0...1) {
                            Text(app: "book.brightness")
                        }
                        .onChange(of: brightness) { _, new in screen?.brightness = new }
                        Image(systemName: "sun.max")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                Section {
                    Button(role: .destructive) {
                        style.reset()
                    } label: {
                        Text(app: "book.reset")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .paper()
            .navigationTitle(Text(app: "book.aa"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(app: "action.done")
                    }
                }
            }
        }
        .onAppear { brightness = screen.map { Double($0.brightness) } ?? 0.5 }
        .onChange(of: style.size) { adopt() }
        .onChange(of: style.lineSpacing) { adopt() }
        .onChange(of: style.margins) { adopt() }
        .onChange(of: style.justified) { adopt() }
        .onChange(of: style.theme) { adopt() }
        .onChange(of: style.typography) { adopt() }
        .onChange(of: style.publisherStyle) { adopt() }
        .onChange(of: style.hyphenation) { adopt() }
        .onChange(of: style.reflowing) { adopt() }
        .onChange(of: style.columns) { adopt() }
    }

    /// The scene's screen - `UIScreen.main` is deprecated.
    private var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
            as? UIWindowScene)?
            .screen
    }

    /// Five tiles: Light, Sepia, Dark, Night, Automatic - each in its own color.
    /// "Automatic" is half dark, half light, each half with its own ink: a gray
    /// "Aa" across both was barely readable on the dark half, and the
    /// split sits in the middle, also with the wider tiles on iPad.
    private var themeChoice: some View {
        HStack(spacing: 10) {
            ForEach(ReadingStyle.ReadingTheme.allCases) { theme in
                Button {
                    style.theme = theme
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            if theme == .automatic {
                                themeTile(.dark)
                                themeTile(.light)
                                    .mask {
                                        HStack(spacing: 0) {
                                            Rectangle(); Color.clear
                                        }
                                    }
                            } else {
                                themeTile(theme)
                            }
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    style.theme == theme ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: style.theme == theme ? 2 : 1)
                        }
                        .frame(height: 56)
                        // Five tiles in one row: "Automatic" only fits on the small iPhone
                        // when it wraps.
                        Text(appKey: "book.theme." + theme.rawValue)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(appKey: "book.theme." + theme.rawValue))
                .accessibilityAddTraits(style.theme == theme ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    /// Paper and "Aa" of a theme - the surface of a tile.
    private func themeTile(_ theme: ReadingStyle.ReadingTheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.paperColor)
            Text(verbatim: "Aa")
                .font(.body.weight(.medium))
                .foregroundStyle(theme.inkColor)
        }
    }

    /// Small A, slider, large A - and minus/plus in tenth steps.
    private var size: some View {
        HStack(spacing: 12) {
            Button {
                style.size = max(
                    ReadingStyle.sizeRange.lowerBound, (style.size - 0.1).rounded(toPlaces: 2))
            } label: {
                Text(verbatim: "A")
                    .font(.footnote)
                    .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(app: "book.smaller"))
            Slider(value: $style.size, in: ReadingStyle.sizeRange, step: 0.05) {
                Text(app: "book.size")
            }
            Button {
                style.size = min(
                    ReadingStyle.sizeRange.upperBound, (style.size + 0.1).rounded(toPlaces: 2))
            } label: {
                Text(verbatim: "A")
                    .font(.title2)
                    .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(app: "book.larger"))
        }
    }

    private func slider(
        _ lookupKey: String, value: Binding<Double>, area: ClosedRange<Double>, step: Double,
        glyph: String,
        publisherStyle: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { new in
                        if publisherStyle { style.publisherStyle = false }
                        value.wrappedValue = new
                    }), in: area, step: step
            ) {
                Text(appKey: lookupKey)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A toggle that switches off the publisher style as soon as it is moved.
    private func switchBinding(_ value: Binding<Bool>, publisherStyle: Bool) -> Binding<Bool> {
        Binding {
            value.wrappedValue
        } set: { new in
            if publisherStyle { style.publisherStyle = false }
            value.wrappedValue = new
        }
    }
}

extension Double {
    fileprivate func rounded(toPlaces spots: Int) -> Double {
        let factor = pow(10.0, Double(spots))
        return (self * factor).rounded() / factor
    }
}
