import AccountsKit
import DesignSystem
import SwiftUI

/// The empty library: the worm on an empty shelf board between two bookends, one sentence,
/// three ways: connect a server, open an EPUB, sample shelf. Start and Library show the same
/// while nothing is there.
///
/// A child profile sets nothing up: it sees the board and the sentence, no buttons.
struct EmptyShelf: View {

    @Environment(\.openWelcome) private var welcome
    @Environment(\.importFile) private var importFile
    @Environment(\.profile) private var profile
    @State private var filePicker = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .bottom) {
                ShelfBoard()
                Worm(.read, edge: 128)
                    .padding(.bottom, 12)
            }
            .frame(height: 170)
            .padding(.bottom, 8)
            Text(app: "shelf.empty.title")
                .font(Typography.title(.title2))
                .foregroundStyle(ColorTheme.typography.color)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(app: profile.kind ? "library.empty.text" : "shelf.empty.text")
                .font(.subheadline)
                .foregroundStyle(ColorTheme.muted.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !profile.kind {
                VStack(spacing: 12) {
                    Button {
                        welcome()
                    } label: {
                        Label(app: "welcome.promise.connect", systemImage: "server.rack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primary)
                    Button {
                        filePicker = true
                    } label: {
                        Label(app: "shelf.empty.epub", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondary)
                    if SampleShelf.present {
                        Button {
                            importFile(SampleShelf.files)
                        } label: {
                            Text(app: "shelf.empty.examples")
                                .font(.subheadline.weight(.medium))
                                .frame(minHeight: TapTarget.atLeast)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .fileImporter(
            isPresented: $filePicker, allowedContentTypes: FileType.all, allowsMultipleSelection: true
        ) {
            result in
            if case .success(let urls) = result, !urls.isEmpty { importFile(urls) }
        }
    }
}

/// An empty wooden board with two bookends, drawn rather than an image so it works with
/// every theme and size.
private struct ShelfBoard: View {

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                bookend
                Spacer()
                bookend
            }
            .frame(width: 210)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.66, green: 0.45, blue: 0.27),
                            Color(red: 0.52, green: 0.34, blue: 0.20),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 250, height: 9)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
        }
        .accessibilityHidden(true)
    }

    private var bookend: some View {
        UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
            .fill(AdaptiveColor(light: 0x8C877C, dark: 0x6E6B64).color)
            .frame(width: 10, height: 48)
    }
}

/// "Connect server" from anywhere: opens the shell's welcome flow.
struct WelcomeOpenKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var openWelcome: @MainActor () -> Void {
        get { self[WelcomeOpenKey.self] }
        set { self[WelcomeOpenKey.self] = newValue }
    }
}
