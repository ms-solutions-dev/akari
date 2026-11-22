import DesignSystem
import SwiftUI

#if os(iOS)
    import UIKit

    /// The app icon choice: the lantern with ribbon is the default, the candle the light
    /// second icon. The icons live in the app's asset catalog (`AppIcon`, `AppIconKerze`);
    /// the previews beside them (`SymbolVorschau...`) exist because an app icon cannot be
    /// loaded as an image.
    enum IconChoice: String, CaseIterable, Identifiable {
        case lantern = "laterne", candle = "kerze"

        var id: String { rawValue }

        /// The name for `setAlternateIconName`; `nil` is the default icon.
        var alternativeName: String? {
            switch self {
            case .lantern: nil
            case .candle: "AppIconKerze"
            }
        }

        var lookupKey: String { "symbol." + rawValue }

        var preview: String {
            switch self {
            case .lantern: "SymbolVorschauLaterne"
            case .candle: "SymbolVorschauKerze"
            }
        }

        @MainActor static var current: IconChoice {
            allCases.first { $0.alternativeName == UIApplication.shared.alternateIconName } ?? .lantern
        }
    }

    /// Two tiles with the icon, name below, checkmark on the chosen one, like the
    /// `ThemePicker`. iOS itself shows a notice after the switch.
    struct IconPicker: View {

        @State private var chosen = IconChoice.current

        var body: some View {
            if UIApplication.shared.supportsAlternateIcons {
                VStack(alignment: .leading, spacing: 8) {
                    Text(app: "appearance.symbol")
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 16) {
                        ForEach(IconChoice.allCases) { symbol in
                            Button {
                                choose(symbol)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(decorative: symbol.preview, bundle: .main)
                                        .resizable()
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                                                .strokeBorder(
                                                    chosen == symbol
                                                        ? Color.accentColor
                                                        : ColorTheme.muted.color.opacity(0.3),
                                                    lineWidth: chosen == symbol ? 2 : 1)
                                        }
                                    HStack(spacing: 3) {
                                        Text(appKey: symbol.lookupKey).font(.caption)
                                        if chosen == symbol {
                                            Image(systemName: "checkmark").font(.caption2.weight(.bold))
                                        }
                                    }
                                    .foregroundStyle(
                                        chosen == symbol ? Color.accentColor : ColorTheme.muted.color)
                                }
                                .frame(minWidth: TapTarget.atLeast, minHeight: TapTarget.atLeast)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(appKey: symbol.lookupKey))
                            .accessibilityAddTraits(chosen == symbol ? [.isSelected] : [])
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }

        private func choose(_ symbol: IconChoice) {
            guard symbol != chosen else { return }
            Haptics.selection()
            // Switch immediately; until iOS shows its notice the tap would seem dead.
            chosen = symbol
            Task {
                do {
                    try await UIApplication.shared.setAlternateIconName(symbol.alternativeName)
                } catch {
                    // Rejected (for example in the background): the choice stays as it was.
                    chosen = IconChoice.current
                }
            }
        }
    }
#endif
