import AccountsKit
import DesignSystem
import Device
import Library
import SourcesKit
import SwiftUI

/// The context menu on the cover, the same everywhere: Continue reading
/// or Open, Show series, Save, Keep, Add to shelf, Reading status,
/// Reset progress. Delete, metadata and shelves belong to the server's
/// web interface and never appear.
extension View {

    func titleMenu(_ title: Title) -> some View {
        modifier(TitleMenu(title: title))
    }

    func seriesMenu(_ series: Series) -> some View {
        modifier(SeriesMenu(series: series))
    }
}

struct TitleMenu: ViewModifier {

    let title: Title

    @State private var deleteQuestion = false

    func body(content: Content) -> some View {
        content
            .contextMenu { TitleMenuContent(title: title, inDetail: false, deleteQuestion: $deleteQuestion) }
            .titleDeleteQuestion(title, isPresented: $deleteQuestion)
    }
}

/// The entries of the title menu, in the context menu on the cover and in the more menu of the
/// title detail (there VoiceOver reaches them; the cover is not a control).
/// In groups: Open and Series, Save, shelf, Keep, Share, Reading status, Reset last.
/// The detail omits Open (the primary button) and Series (the link in the header).
struct TitleMenuContent: View {

    let title: Title
    let inDetail: Bool
    @Binding var deleteQuestion: Bool

    @Environment(LibraryService.self) private var inventory
    @Environment(ReadCall.self) private var reader
    @Environment(\.device) private var device
    @Environment(\.profile) private var profile

    var body: some View {
        let state = inventory.readingState(title.identifier)
        let status = ReadStatus(state)
        if !inDetail {
            Button {
                reader.open(title)
            } label: {
                Label {
                    Text(
                        appKey: state?.started == true
                            ? title.kind.continueKey : title.kind.openKey)
                } icon: {
                    Image(systemName: title.kind.isAudible ? "headphones" : "book")
                }
            }
            if let series = title.series {
                NavigationLink(value: Target.series(series.identifier)) {
                    Label(app: "menu.series", systemImage: "books.vertical")
                }
            }
            Divider()
        }
        SaveButton(target: .title(title.identifier))
        CollectionMenu(target: .title(title.identifier))
        KeepButton(title: title)
        // Pass the file on, e.g. AirDrop to a computer.
        // Audiobooks are tracks, not a file: no entry. A child profile does not share.
        if !profile.kind, inventory.source(title.identifier.source)?.file(title) != nil {
            Divider()
            Button {
                reader.titleToShare = title
            } label: {
                Label(app: "share.title", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        ReadingStatusSwitch(title: title, status: status)
        // What is on the device can only be removed here, and not
        // from a child profile.
        if title.identifier.source.provider == .device, device != nil, !profile.kind {
            Button(role: .destructive) {
                deleteQuestion = true
            } label: {
                Label(app: "device.delete", systemImage: "trash")
            }
        }
    }
}

extension View {
    /// The confirmation before "Delete from device", attached where the menu is attached.
    func titleDeleteQuestion(_ title: Title, isPresented: Binding<Bool>) -> some View {
        modifier(TitleDeleteQuestion(title: title, unresolved: isPresented))
    }
}

private struct TitleDeleteQuestion: ViewModifier {
    let title: Title
    @Binding var unresolved: Bool

    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices
    @Environment(\.device) private var device

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text(app: "device.delete.question"), isPresented: $unresolved, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                notices.tryRun {
                    try device?.erase(title.identifier)
                    await inventory.refresh(only: DeviceSource.identifier)
                }
            } label: {
                Text(app: "device.delete")
            }
        } message: {
            Text(verbatim: title.name)
        }
    }
}

struct SeriesMenu: ViewModifier {

    let series: Series

    @Environment(LibraryService.self) private var inventory
    @Environment(ReadCall.self) private var reader
    @Environment(Notices.self) private var notices
    @State private var question = false

    func body(content: Content) -> some View {
        let state = inventory.seriesState(series.identifier)
        content
            .contextMenu {
                if let current = state.current {
                    Button {
                        reader.open(current)
                    } label: {
                        Label {
                            Text(
                                appKey: state.state != nil
                                    ? series.kind.continueKey : series.kind.openKey)
                        } icon: {
                            Image(systemName: series.kind.isAudible ? "headphones" : "book")
                        }
                    }
                }
                NavigationLink(value: Target.series(series.identifier)) {
                    Label(app: "menu.series", systemImage: "books.vertical")
                }
                Divider()
                SaveButton(target: .series(series.identifier))
                CollectionMenu(target: .series(series.identifier))
                Divider()
                if !state.completed {
                    Button {
                        question = true
                    } label: {
                        Label(app: "series.allRead", systemImage: "checkmark.circle")
                    }
                }
            }
            .markAllReadQuestion(series, isPresented: $question)
    }
}

/// The reading-status entries, one per state rather than a submenu:
/// "Mark as read" for unread and started titles, "Mark as unread" for read ones; plus
/// "Reset progress" only when something has been started. Only the reader sets "started".
struct ReadingStatusSwitch: View {

    let title: Title
    let status: ReadStatus

    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices

    var body: some View {
        if status == .read {
            Button {
                notices.tryRun { try await inventory.set(.unread, for: title.identifier) }
            } label: {
                Label(appKey: title.kind.asUnreadKey, systemImage: "circle")
            }
        } else {
            Button {
                notices.tryRun {
                    try await inventory.set(.read, for: title.identifier)
                    Haptics.success()
                }
            } label: {
                Label(appKey: title.kind.asReadKey, systemImage: "checkmark.circle")
            }
        }
        if status == .started {
            Button(role: .destructive) {
                notices.tryRun { try await inventory.forget(progressFor: title.identifier) }
            } label: {
                Label(app: "menu.reset", systemImage: "arrow.counterclockwise")
            }
        }
    }
}

/// "Save" or "Remove from saved": a button that knows its state; third in the
/// context menu, a chip in the detail (``SaveChip``).
struct SaveButton: View {

    let target: SaveTarget

    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices

    var body: some View {
        let saved = inventory.shelf.saved.contains(target)
        Button {
            notices.tryRun {
                try await inventory.save(target, saved: !saved)
                Haptics.selection()
            }
        } label: {
            Label(
                app: saved ? "menu.unsave" : "menu.save",
                systemImage: saved ? "bookmark.slash" : "bookmark")
        }
    }
}

/// The chip row of a detail: scrolls horizontally, each chip at its own width,
/// never a split word.
struct ChipRow<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .fixedSize(horizontal: true, vertical: false)
        }
        .scrollClipDisabled()
    }
}

/// The "Collection" chip in the detail: a menu with the same entries as the
/// context menu; filled if the target is in a collection.
struct CollectionChip: View {

    let target: SaveTarget
    @Environment(LibraryService.self) private var inventory

    var body: some View {
        if inventory.shelf.capabilities[target.source]?.contains(.editCollections) == true {
            let inside = inventory.shelf.collections.contains {
                $0.identifier.source == target.source && $0.contains(target)
            }
            Menu {
                CollectionMenu(target: target)
            } label: {
                Chip(Text(app: "collection.chip"), glyph: "square.stack", active: inside)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        }
    }
}

/// The "Saved" chip in title and series detail, filled when saved.
struct SaveChip: View {

    let target: SaveTarget

    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let saved = inventory.shelf.saved.contains(target)
        Button {
            notices.tryRun {
                try await inventory.save(target, saved: !saved)
            }
        } label: {
            Chip(Text(app: "title.saved"), glyph: "bookmark", active: saved)
                // The ribbon bounces once when it is set.
                .symbolEffect(.bounce.down, value: saved)
                .symbolEffectsRemoved(reduceMotion)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: saved)
        .accessibilityLabel(Text(app: saved ? "menu.unsave" : "menu.save"))
    }
}

extension View {
    /// The confirmation before "All read"; it writes volume by volume to the server.
    func markAllReadQuestion(_ series: Series, isPresented: Binding<Bool>) -> some View {
        modifier(MarkAllReadQuestion(series: series, isPresented: isPresented))
    }
}

private struct MarkAllReadQuestion: ViewModifier {

    let series: Series
    @Binding var isPresented: Bool
    @Environment(LibraryService.self) private var inventory
    @Environment(Notices.self) private var notices

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text(appKey: Formats.lookupKey("series.allRead.question", kind: series.kind)),
            isPresented: $isPresented, titleVisibility: .visible
        ) {
            Button {
                notices.tryRun {
                    try await inventory.allRead(series.identifier)
                    Haptics.success()
                }
            } label: {
                Text(app: "series.allRead")
            }
            Button(role: .cancel) {
            } label: {
                Text(app: "action.cancel")
            }
        } message: {
            Text(verbatim: series.name)
        }
    }
}
