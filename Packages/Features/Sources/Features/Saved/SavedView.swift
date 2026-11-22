import DesignSystem
import Library
import SourcesKit
import SwiftUI

/// The saved list as an ordered page: dragging reorders, swiping removes. The top entry
/// is the candidate for Start, "what I want to read next". When empty, the worm appears
/// for the first time.
struct SavedView: View {

    @Environment(LibraryService.self) private var inventory
    @Environment(AppCore.self) private var core

    var body: some View {
        let entries = inventory.shelf.savedEntries
        Group {
            if entries.isEmpty {
                EmptyState(worm: Text(app: "saved.empty.title"), text: Text(app: "saved.empty.text"))
                    .paper()
            } else {
                List {
                    // The shelf may no longer know an entry (account signed out);
                    // the offsets refer to the list it does know.
                    ForEach(entries) { entry in
                        EntryRow(entry: entry, withKind: true)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { from, to in
                        let full = inventory.shelf.saved
                        inventory.moveSaved(
                            from: SavedView.spots(from, visible: entries, full: full),
                            to: SavedView.spot(to, visible: entries, full: full))
                    }
                    .onDelete { spots in
                        Task {
                            for i in spots.sorted(by: >) where entries.indices.contains(i) {
                                try? await inventory.save(SavedView.target(entries[i]), saved: false)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .paper()
                .toolbar {
                    // Dragging also works without edit mode (long press); the button
                    // is for those who do not know that. It is absent on the Mac (test runs).
                    #if os(iOS)
                        ToolbarItem(placement: .primaryAction) {
                            EditButton()
                        }
                    #endif
                }
            }
        }
        .navigationTitle(Text(app: "start.saved"))
        .toolbarTitleDisplayMode(.inline)
        // Sync with iCloud once on open, so an entry saved on another device shows up
        // here without anyone syncing by hand.
        .onAppear { core.sameCloudSince() }
    }

    static func target(_ entry: Shelf.Item) -> SaveTarget {
        switch entry {
        case .title(let t): .title(t.identifier)
        case .series(let s): .series(s.identifier)
        }
    }

    /// The offsets in the full saved list for the offsets in the visible list; the two
    /// diverge as soon as an entry belongs to a signed-out account.
    static func spots(_ spots: IndexSet, visible: [Shelf.Item], full: [SaveTarget]) -> IndexSet {
        IndexSet(
            spots.compactMap { i in
                visible.indices.contains(i) ? full.firstIndex(of: SavedView.target(visible[i])) : nil
            })
    }

    static func spot(_ spot: Int, visible: [Shelf.Item], full: [SaveTarget]) -> Int {
        guard visible.indices.contains(spot) else { return full.count }
        return full.firstIndex(of: SavedView.target(visible[spot])) ?? full.count
    }
}
