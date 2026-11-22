import SwiftUI

#Preview("Row: index, cover, running, badge") {
    PreviewShelf.AllThemes {
        VStack(spacing: 0) {
            Row(index: "12", name: Text(verbatim: "Volume 12"), secondaryLine: Text(verbatim: "198 pages"))
            Divider()
            Row(
                index: "13", name: Text(verbatim: "Volume 13"), secondaryLine: Text(verbatim: "p. 112/198"),
                ongoing: true)
            Divider()
            Row(
                index: "14", name: Text(verbatim: "Volume 14"), secondaryLine: Text(verbatim: "204 pages"),
                badge: Text(verbatim: "New"))
            Divider()
            Row(
                name: Text(verbatim: "The Glass Orchard"),
                secondaryLine: Text(verbatim: "Ines Moreau · 62 %"),
                badge: Text(verbatim: "Kept")
            ) {
                CoverFrame { PreviewShelf.glassOrchard }.frame(width: 34)
            }
        }
    }
}
