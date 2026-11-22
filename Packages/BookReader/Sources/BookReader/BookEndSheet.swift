import DesignSystem
import SwiftUI

/// The sheet after the last page: "Book finished", the next volume as
/// primary button - or, without a series, a saved book as a suggestion; plus "To the
/// series" and "Close". Never a review prompt.
struct BookEndSheet: View {

    let book: ReaderBook
    let theme: ReadingStyle.ReadingTheme
    let back: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                // A finished book is a success: the worm cheers.
                Worm(.cheer, edge: 120)
                Text(app: "book.end")
                    .font(Typography.title(.title2))
                Text(verbatim: [book.name, book.subline].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                if let continuation = book.continuation {
                    Button {
                        continuation.open()
                    } label: {
                        VStack(spacing: 2) {
                            Text(
                                app: continuation.kind == .nextVolume
                                    ? "reader.continueReading" : "book.savedSuggestion")
                            Text(
                                verbatim: [continuation.name, continuation.subline].compactMap { $0 }.joined(
                                    separator: " · ")
                            )
                            .font(.caption)
                            .opacity(0.8)
                            .lineLimit(2)
                        }
                        .frame(maxWidth: 320)
                    }
                    .buttonStyle(.primary)
                }
                if let toSeries = book.toSeries {
                    Button {
                        dismiss()
                        toSeries()
                    } label: {
                        Text(app: "reader.toSeries")
                            .frame(maxWidth: 320)
                            .frame(minHeight: TapTarget.atLeast)
                    }
                }
                Button {
                    back()
                } label: {
                    Text(app: "book.lastPage")
                        .frame(maxWidth: 320)
                        .frame(minHeight: TapTarget.atLeast)
                }
                .foregroundStyle(.secondary)
                Button {
                    dismiss()
                } label: {
                    Text(app: "action.close")
                        .frame(maxWidth: 320)
                        .frame(minHeight: TapTarget.atLeast)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paperColor.ignoresSafeArea())
    }
}
