import DesignSystem
import Library
import OfflineStore
import SourcesKit
import SwiftUI

/// What is on the device, as a page of its own behind "All" of the Start row. Usage on top,
/// then what is loading right now, then a grid per kind; a long press releases it.
struct DeviceView: View {

    @Environment(StockService.self) private var stock
    @Environment(LibraryService.self) private var inventory
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.theme) private var theme
    @State private var free: Int64?

    var body: some View {
        let list = DeviceView.list(stock: stock, inventory: inventory)
        Group {
            if list.isEmpty {
                EmptyState(glyph: "arrow.down.circle", title: Text(app: "storage.keep.empty"))
                    .paper()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        usage
                        let ongoing = list.filter { !$0.keep.done }
                        if !ongoing.isEmpty {
                            part(Text(app: "device.loading"), ongoing)
                        }
                        ForEach(Kind.allCases, id: \.self) { kind in
                            let group = list.filter { $0.keep.done && $0.keep.kind == kind }
                            if !group.isEmpty {
                                part(
                                    Text("\(Text(appKey: "segment." + kind.rawValue)) (\(group.count))"),
                                    group)
                            }
                        }
                    }
                    .padding()
                }
                .paper()
            }
        }
        .navigationTitle(Text(app: "storage.keep"))
        .toolbarTitleDisplayMode(.inline)
        .task {
            let place = URL(filePath: NSHomeDirectory())
            free =
                (try? place.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
    }

    /// "4.2 GB used · 38 GB free" with a bar: how much space the downloads take.
    private var usage: some View {
        let used = stock.sum
        return VStack(alignment: .leading, spacing: 8) {
            Text(
                verbatim: Phrase.from(
                    "device.assignment", Formats.bytes(used), free.map(Formats.bytes) ?? "–")
            )
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            if let free {
                GeometryReader { space in
                    Capsule().fill(theme.hairline.color)
                        .overlay(alignment: .leading) {
                            Capsule().fill(theme.accent.color)
                                .frame(
                                    width: space.size.width * CGFloat(used) / CGFloat(max(used + free, 1)))
                        }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
        }
    }

    private func part(_ title: Text, _ group: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title.font(.headline)
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(
                            minimum: TileMetrics.raster(width), maximum: TileMetrics.gridCap(width)),
                        spacing: 12, alignment: .top)
                ],
                alignment: .leading, spacing: 20
            ) {
                ForEach(group) { e in
                    TitleTile(
                        title: e.title, width: TileMetrics.raster(width),
                        secondaryLine: DeviceView.secondaryLine(e.keep), withKind: true
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            stock.release(e.keep.identifier)
                        } label: {
                            Label(app: "storage.delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    struct Item: Identifiable {
        let keep: KeptItem
        let title: Title
        var id: TitleID { keep.identifier }
    }

    /// Running ones first, then the newest. The title comes from the data package (with the cover on the
    /// device), otherwise from the catalog; without either the entry is dropped.
    @MainActor
    static func list(stock: StockService, inventory: LibraryService) -> [Item] {
        let done = Dictionary(stock.snapshots.map { ($0.identifier, $0) }) { a, _ in a }
        return stock.entries.values.map { stock.withProgress($0) }
            .sorted { a, b in a.done != b.done ? !a.done : a.since > b.since }
            .compactMap { b in
                (done[b.identifier] ?? b.title ?? inventory.titleForDetail(b.identifier)).map {
                    Item(keep: b, title: $0)
                }
            }
    }

    /// "45 %" while loading, otherwise the size.
    static func secondaryLine(_ b: KeptItem) -> Text {
        if case .ongoing(let fraction, _) = b.state {
            return Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0))))
        }
        return Text(verbatim: Formats.bytes(b.size))
    }
}
