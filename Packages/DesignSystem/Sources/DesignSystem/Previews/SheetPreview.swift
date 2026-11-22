import SwiftUI

#Preview("Sheet") {
    Sheet(title: Text(verbatim: "Appearance")) {
        List {
            Section {
                Text(verbatim: "Like the system")
                Text(verbatim: "Light")
                Text(verbatim: "Dark")
            }
        }
    }
    .theme(.terracotta)
}
