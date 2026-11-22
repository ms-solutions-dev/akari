import SwiftUI

#Preview("Progress bar: 0, 31 %, 62 %, done") {
    PreviewShelf.AllThemes {
        VStack(alignment: .leading, spacing: 14) {
            ProgressBar(fraction: 0, text: Text(verbatim: "Not started"))
            ProgressBar(fraction: 0.31, text: Text(verbatim: "Page 63 of 205"))
            ProgressBar(fraction: 0.62, text: Text(verbatim: "62 %"))
            ProgressBar(fraction: 1, text: Text(verbatim: "Read"))
            HStack(spacing: 8) {
                Badge(Text(verbatim: "New"))
                Badge(Text(verbatim: "Kept"))
                Badge(Text(verbatim: "Volume 8"), audio: .muted)
            }
        }
    }
}
