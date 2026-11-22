import SwiftUI

#Preview("Banner: offline, disruption, filter, hint") {
    PreviewShelf.AllThemes {
        VStack(spacing: 12) {
            Banner(.offline, text: Text(verbatim: "Offline — what you kept is here, the rest waits.")) {
                Button(action: {}) { Text(verbatim: "Try again") }
            }
            Banner(.disruption, text: Text(verbatim: "Books: unreachable")) {
                Button(action: {}) { Text(verbatim: "Try again") }
                Button(action: {}) { Text(verbatim: "Check account") }
            }
            Banner(.filter, text: Text(verbatim: "Unread only · 41 titles")) {
                Button(action: {}) { Text(verbatim: "Clear filter") }
            }
            Banner(
                .hint,
                text: Text(verbatim: "This account may not keep anything here — reading still works."))
        }
    }
}
