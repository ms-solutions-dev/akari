import SwiftUI

/// "In the book" outside the reader, from the title detail: people, places and
/// terms from the ``TermCache`` - without opening the book. Spoiler protection applies up to
/// the position where the reader last was. Only the reader shows maps, their images come
/// from the EPUB.
public struct InBookPage: View {
    let id: String
    let file: URL

    @State private var persistence: TermCache?
    @State private var loaded = false
    @State private var unresolved: Glossary.Item?
    @Environment(\.colorScheme) private var schema

    public init(id: String, file: URL) {
        self.id = id
        self.file = file
    }

    /// Is there anything to show yet? Only a look at the file system - the store is read later.
    public static func present(_ file: URL) -> Bool {
        TermCache.place(for: file).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public var body: some View {
        let theme: ReadingStyle.ReadingTheme = schema == .dark ? .dark : .light
        let terms = persistence?.chapterIndex.map(TermIndex.init(chapter:))
        let state = BookController.savedState(id)
        Group {
            if loaded {
                InBookView(
                    glossary: persistence?.glossary, terms: terms, wordHere: state, cards: [], theme: theme
                ) { unresolved = $0 }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let file = file
            persistence = await Task.detached(priority: .userInitiated) { TermCache.load(for: file) }
                .value
            loaded = true
        }
        .sheet(item: $unresolved) { e in
            GlossarySheet(
                entry: e, glossary: persistence?.glossary, theme: theme, terms: terms, wordHere: state
            )
            .presentationDetents([.medium, .large])
        }
    }
}
