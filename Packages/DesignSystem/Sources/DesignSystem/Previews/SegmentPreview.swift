import SwiftUI

private struct SegmentProbe: View {
    @State private var choice = "alle"

    var body: some View {
        Segment(
            selection: $choice,
            fields: [
                ("alle", Text(verbatim: "All")), ("manga", Text(verbatim: "Manga")),
                ("buch", Text(verbatim: "Books")),
                ("hoer", Text(verbatim: "Audiobooks")),
            ])
    }
}

#Preview("Segment") {
    PreviewShelf.AllThemes {
        SegmentProbe()
    }
}
