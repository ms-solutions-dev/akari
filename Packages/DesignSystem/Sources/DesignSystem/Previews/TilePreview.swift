import SwiftUI

#Preview("Tile: states") {
    PreviewShelf.AllThemes {
        HStack(alignment: .top, spacing: 12) {
            Tile(
                name: Text(verbatim: "Island Saga"), secondaryLine: Text(verbatim: "Volume 47 · p. 63/205"),
                progress: 0.31
            ) {
                CoverFrame { PreviewShelf.islandSaga }
            }
            Tile(
                name: Text(verbatim: "The Glass Orchard"), secondaryLine: Text(verbatim: "Ines Moreau"),
                badge: Text(verbatim: "New")
            ) {
                CoverFrame { PreviewShelf.glassOrchard }
            }
            Tile(
                name: Text(verbatim: "The Last Signal"), secondaryLine: Text(verbatim: "3:12 h left"),
                badge: Text(verbatim: "Kept"), progress: 0.62
            ) {
                CoverFrame { PreviewShelf.lastSignal }
            }
            // Without a cover: the placeholder - how a title looks whose image is still missing.
            Tile(
                name: Text(verbatim: "A very long title that needs two lines"),
                secondaryLine: Text(verbatim: "Book")
            ) {
                CoverFrame { CoverPlaceholder(glyph: "book.closed") }
            }
        }
    }
}

#Preview("Tile: Dynamic Type AX3") {
    HStack(alignment: .top, spacing: 12) {
        Tile(
            name: Text(verbatim: "Island Saga"), secondaryLine: Text(verbatim: "Volume 47 · p. 63/205"),
            progress: 0.31
        ) {
            CoverFrame { PreviewShelf.islandSaga }
        }
        Tile(
            name: Text(verbatim: "The Glass Orchard"), secondaryLine: Text(verbatim: "Ines Moreau"),
            badge: Text(verbatim: "New")
        ) {
            CoverFrame { PreviewShelf.glassOrchard }
        }
    }
    .padding()
    .theme(.ink)
    .environment(\.dynamicTypeSize, .accessibility3)
}
