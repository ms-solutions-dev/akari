import SwiftUI

#Preview("Empty state: empty, loading, error, offline, parent account") {
    PreviewShelf.AllThemes {
        VStack(spacing: 24) {
            EmptyState(
                glyph: "books.vertical", title: Text(verbatim: "Nothing on the shelf yet"),
                text: Text(
                    verbatim: "As soon as a server is signed in, what you read last appears here.")
            ) {
                Button(action: {}) { Text(verbatim: "Set up server") }.buttonStyle(.borderedProminent)
            }
            .frame(height: 260)
            EmptyState(title: Text(verbatim: "Reading the shelf …")) {
                ProgressView()
            } action: {
                EmptyView()
            }
            .frame(height: 140)
            EmptyState(
                glyph: "exclamationmark.triangle", title: Text(verbatim: "Server is not answering properly"),
                text: Text(verbatim: "comics.example is there, but not quite itself. Try again later.")
            )
            .frame(height: 200)
            EmptyState(
                glyph: "wifi.slash", title: Text(verbatim: "Offline"),
                text: Text(verbatim: "What you kept is here, the rest waits for the network.")
            )
            .frame(height: 200)
            EmptyState(
                glyph: "lock", title: Text(verbatim: "Nothing kept"),
                text: Text(
                    verbatim: "This account may not keep anything on buecher.example — reading still works.")
            )
            .frame(height: 200)
        }
    }
}
