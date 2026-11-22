import SwiftUI

#Preview("Genre card: three, two, one cover") {
    PreviewShelf.AllThemes {
        HStack(spacing: 10) {
            GenreCard(
                name: Text(verbatim: "Seinen"), count: Text(verbatim: "9 series"),
                cover: [PreviewShelf.islandSaga, PreviewShelf.northSaga, PreviewShelf.lastSignal])
            GenreCard(
                name: Text(verbatim: "Science fiction"), count: Text(verbatim: "31 books"),
                cover: [PreviewShelf.glassOrchard, PreviewShelf.lastSignal])
            GenreCard(
                name: Text(verbatim: "Crime"), count: Text(verbatim: "1 audiobook"),
                cover: [PreviewShelf.lastSignal])
        }
    }
}
