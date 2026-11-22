import DesignSystem
import Observation
import SourcesKit
import SwiftUI

/// The slot for "Read": whoever wants to open a title calls here. The comic reader and the
/// book reader hang on it; the player is next. Until then the shell shows the notice sheet
/// for audiobooks, so every button already does something and never changes its text.
@MainActor
@Observable
final class ReadCall {
    /// The title that should be opened now; the shell shows its sheet for it.
    var title: Title?

    /// Where to go after closing, "To series" from the end-of-volume sheet.
    /// The start page takes the jump and puts the target on its stack.
    var jump: Target?

    /// The audiobook currently in the player; the mini player reopens it.
    var ongoing: Title?

    /// The title whose file should be shared; the shell shows the share sheet.
    var titleToShare: Title?

    func open(_ title: Title) {
        Haptics.selection()
        self.title = title
    }

    func jump(to target: Target) {
        title = nil
        jump = target
    }
}

/// The sheet while no reader is available: cover, name, one sentence. For audiobooks, and
/// for books when no reader is plugged in (on the Mac).
struct ReaderPreviewView: View {

    let title: Title

    var body: some View {
        Sheet(title: Text(app: "read.title")) {
            VStack(spacing: 20) {
                Cover(title, width: 140)
                Text(verbatim: title.name)
                    .font(Typography.title(.title2))
                    .multilineTextAlignment(.center)
                Text(app: "read.soon")
                    .font(.subheadline)
                    .foregroundStyle(ColorTheme.muted.color)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The sheet when book or audiobook did not arrive: the sentence from the catalog, never
/// the description of a `URLError`, and two buttons: "Try again", which continues where the
/// fetch broke off, and Close.
struct FetchFailureView: View {

    /// The sentence about the reason: "The book could not be loaded."
    let lookupKey: String
    let failure: SourceError
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: failure.glyph)
                .font(.largeTitle)
                .foregroundStyle(ColorTheme.muted.color)
            Text(appKey: lookupKey)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Text(appKey: failure.messageKey)
                .font(.caption)
                .foregroundStyle(ColorTheme.muted.color)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if !failure.final {
                    Button(action: retry) {
                        Text(app: "disruption.again")
                    }
                    .buttonStyle(.primary)
                }
                Button(action: close) {
                    Text(app: "action.close")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(32)
    }
}

extension SourceError {
    /// The icon for the error: the network, the account, the server.
    var glyph: String {
        switch self {
        case .unreachable: "wifi.exclamationmark"
        case .signedOut, .denied: "person.crop.circle.badge.exclamationmark"
        case .serverDisruption, .unreadable, .notPossible: "exclamationmark.triangle"
        case .notFound: "questionmark.folder"
        }
    }
}
