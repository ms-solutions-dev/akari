import AccountsKit
import DesignSystem
import Library
import OfflineStore
import SourcesKit
import SwiftUI

/// The storage sheet: downloads on top (each title with size, the total, swipe to
/// delete), below it the cache with a number, the slider (1-8 GB) and "Clear". Two
/// numbers, kept apart: a download is intentional, the cache a side effect.
struct StorageView: View {

    @Environment(StockService.self) private var stock
    @Environment(LibraryService.self) private var inventory
    @Environment(\.profile) private var profile
    // Per device, not per profile: the cache is shared, so is its behavior.
    @AppStorage(Cache.preloadAtHomeKey, store: .standard) private var upfrontAtHome = true
    @State private var cache: Int64?
    @State private var cover: Int?
    @State private var limit: Double = Double(Cache.limit()) / Double(1 << 30)

    var body: some View {
        let entries = stock.entries.values.sorted { $0.since > $1.since }
        List {
            Section {
                if entries.isEmpty {
                    Text(app: "storage.keep.empty")
                        .font(.subheadline)
                        .foregroundStyle(ColorTheme.muted.color)
                } else {
                    ForEach(entries) { e in
                        line(e)
                            // Delete is red: the theme accent used to tint the
                            // swipe button.
                            .swipeActions(edge: .trailing, allowsFullSwipe: !profile.kind) {
                                if !profile.kind {
                                    Button(role: .destructive) {
                                        stock.release(e.identifier)
                                    } label: {
                                        Label(app: "storage.delete", systemImage: "trash")
                                    }
                                    // Swipe area with white text: always the light signal value;
                                    // the dark one (pastel red) would only reach about 1.9:1 on white.
                                    .tint(AdaptiveColor(ColorTheme.failure.light).color)
                                }
                            }
                    }
                    LabeledContent {
                        Text(verbatim: Formats.bytes(stock.sum)).monospacedDigit()
                    } label: {
                        Text(app: "storage.keep.sum")
                    }
                    .font(.subheadline.weight(.medium))
                }
            } header: {
                Text(app: "storage.keep")
            }

            Section {
                LabeledContent {
                    if let cache {
                        Text(verbatim: Formats.bytes(cache)).monospacedDigit()
                    } else {
                        ProgressView()
                    }
                } label: {
                    Text(app: "storage.cache")
                }
                if let cover, cover > 0 {
                    LabeledContent {
                        Text(verbatim: Formats.bytes(Int64(cover))).monospacedDigit()
                    } label: {
                        Text(app: "storage.ofWhichCover")
                    }
                    .font(.subheadline)
                    .foregroundStyle(ColorTheme.muted.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        Text(verbatim: limit.formatted(.number.precision(.fractionLength(1))) + " GB")
                            .monospacedDigit()
                    } label: {
                        Text(app: "storage.limit")
                    }
                    Slider(value: $limit, in: 1...8, step: 0.5)
                        .onChange(of: limit) { _, new in
                            Cache.set(limit: Int64(new * Double(1 << 30)))
                        }
                }
                Toggle(isOn: $upfrontAtHome) {
                    Text(app: "storage.preloadAtHome")
                }
                if !profile.kind {
                    Button(role: .destructive) {
                        try? Cache.clearOut()
                        cache = Cache.size()
                        cover = 0
                    } label: {
                        Text(app: "storage.clear")
                    }
                    .disabled((cache ?? 0) == 0)
                }
            } header: {
                Text(app: "storage.cache")
            } footer: {
                Text(app: "storage.cache.text")
            }
        }
        .paper()
        .navigationTitle(Text(app: "storage.title"))
        .toolbarTitleDisplayMode(.inline)
        .task {
            cache = await Task.detached(priority: .utility) { Cache.size() }.value
            cover = await ImageLoader.shared.size()
        }
    }

    @ViewBuilder
    private func line(_ e: KeptItem) -> some View {
        let e = stock.withProgress(e)
        let title = inventory.title(e.identifier)
        HStack(spacing: 12) {
            if let title {
                Cover(title, width: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title.map { Display($0, inBookSeries: false).name } ?? e.name)
                    .font(Typography.name(.body))
                    .foregroundStyle(ColorTheme.typography.color)
                    .lineLimit(1)
                Text(verbatim: StorageView.secondaryLine(e))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(ColorTheme.muted.color)
            }
            Spacer()
            if case .ongoing(let fraction, _) = e.state { KeepRing(fraction: fraction) }
        }
    }

    /// "74.5 MB", for audiobooks "108 tracks · 641 MB", while fetching "12 MB · 38 %",
    /// when disrupted "interrupted".
    static func secondaryLine(_ e: KeptItem) -> String {
        switch e.state {
        case .done where e.kind.isAudible:
            return Phrase.from("keep.tracks", e.files.count) + " · " + Formats.bytes(e.size)
        case .done: return Formats.bytes(e.size)
        case .ongoing(let fraction, let bytes):
            return Formats.bytes(bytes) + " · " + fraction.formatted(.percent.precision(.fractionLength(0)))
        case .disrupted: return Phrase.from("keep.disrupted")
        }
    }
}
