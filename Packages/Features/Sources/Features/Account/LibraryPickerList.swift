import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The per-library switches of a server, on the account page and in the sheet after sign-in.
/// The last enabled one cannot be switched off: an account without a library would be an
/// empty shelf without explanation.
struct LibraryPickerList: View {

    let identifier: SourceID
    let libraries: [SubLibrary]
    /// Reports that the choice changed.
    var changed: () -> Void = {}

    @State private var from: Set<String> = []

    var body: some View {
        ForEach(libraries) { b in
            Toggle(
                isOn: Binding(
                    get: { !from.contains(b.id) },
                    set: { to in
                        if to { from.remove(b.id) } else { from.insert(b.id) }
                        LibraryPicker.set(from: from, for: identifier)
                        changed()
                    })
            ) {
                Text(verbatim: b.name)
            }
            .disabled(!from.contains(b.id) && libraries.count - from.count <= 1)
        }
        .onAppear { from = LibraryPicker.from(identifier) }
    }
}

/// The sheet after sign-in when the server has several libraries and many titles
/// (`LibraryPicker.ask`): which ones should go into the app? All are preselected.
struct LibraryPickerSheet: View {

    let identifier: SourceID
    let libraries: [SubLibrary]
    let title: Int
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LibraryPickerList(identifier: identifier, libraries: libraries)
                } footer: {
                    Text(verbatim: Phrase.from("libraryPicker.text", Formats.integer(title)))
                }
            }
            .paper()
            .navigationTitle(Text(app: "libraryPicker.title"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: done) {
                        Text(app: "libraryPicker.done")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
