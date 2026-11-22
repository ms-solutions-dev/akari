import DesignSystem
import Library
import NetworkLocation
import OfflineStore
import SourcesKit
import SwiftUI

/// The download button, in the context menu and as a chip in the detail: "Download",
/// "Cancel" while fetching, then "Downloaded" (chip) or "Delete download" (menu). Only where
/// the account allows it (`Capabilities.keep`); the parent account does not see it.
///
/// In the menu the red entry deletes immediately, like "Remove download" in podcasts and
/// books: a confirmation sheet on a menu item never appears, because the menu disappears
/// with the tap and the view with it. The chip in the detail asks first, since it stays.
///
/// **Audiobooks** are large, 400 to 700 MB rather than 0.8, so the chip asks before
/// fetching and says what is coming: "634 tracks · 608 MB", plus the on-the-go hint as in
/// the "Download up to volume" sheet. Only the detail knows the tracks, so the tap fetches
/// the volume before the sheet opens; the volume then goes along to the offline store so
/// the server is not asked twice. In the menu, where no sheet stays, the entry carries the
/// size from the list in its name: "Download (608 MB)".
struct KeepButton: View {

    let title: Title
    /// As a chip (with frame) or as a menu item.
    var chip = false

    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock
    @Environment(NetworkWatch.self) private var network
    @Environment(Notices.self) private var notices
    @Environment(\.imageTransport) private var transport
    @State private var question = false
    /// The audiobook's volume once it is fetched; the sheet asks with it.
    @State private var audiobookQuestion: AudioManifest?
    @State private var fetchesVolume = false

    var body: some View {
        if inventory.shelf.capabilities(title.identifier).contains(.keep) {
            let entry = stock.entry(title.identifier)
            Group {
                switch entry?.state {
                case .done where !chip:
                    Button(role: .destructive) {
                        stock.release(title.identifier)
                    } label: {
                        Label(app: "keep.share", systemImage: "trash")
                    }
                case .done:
                    Button {
                        question = true
                    } label: {
                        Chip(Text(app: "title.loaded"), glyph: "arrow.down.circle", active: true)
                    }
                    .confirmationDialog(
                        Text(app: "keep.share.question"), isPresented: $question, titleVisibility: .visible
                    ) {
                        Button(role: .destructive) {
                            stock.release(title.identifier)
                        } label: {
                            Text(
                                verbatim: Phrase.from(
                                    "keep.share.with", Formats.bytes(entry?.size ?? 0)))
                        }
                    } message: {
                        Text(verbatim: title.name)
                    }
                case .ongoing(let start, _):
                    let fraction = stock.progress(title.identifier)?.fraction ?? start
                    Button {
                        stock.release(title.identifier)
                    } label: {
                        if chip {
                            HStack(spacing: 6) {
                                KeepRing(fraction: fraction)
                                Text(app: "keep.cancel")
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                        } else {
                            Label(app: "keep.cancel", systemImage: "xmark.circle")
                        }
                    }
                case .none where title.kind.isAudible && chip,
                    .disrupted where title.kind.isAudible && chip:
                    Button {
                        askAudiobook()
                    } label: {
                        Chip(Text(app: "title.keep"), glyph: "arrow.down.circle", active: false)
                            .opacity(fetchesVolume ? 0.5 : 1)
                    }
                    .disabled(fetchesVolume)
                    .confirmationDialog(
                        Text(app: "keep.audiobook.question"),
                        isPresented: Binding(
                            get: { audiobookQuestion != nil }, set: { if !$0 { audiobookQuestion = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button {
                            if let volume = audiobookQuestion { requestKeep(volume) }
                        } label: {
                            Text(
                                verbatim: Phrase.from(
                                    "keep.audiobook.with",
                                    Formats.bytes(audiobookQuestion?.size ?? title.size ?? 0)))
                        }
                    } message: {
                        Text(
                            verbatim: KeepButton.audiobookPhrase(
                                title, volume: audiobookQuestion, onTheGo: onTheGo))
                    }
                default:
                    Button {
                        requestKeep()
                    } label: {
                        if chip {
                            Chip(Text(app: "title.keep"), glyph: "arrow.down.circle", active: false)
                        } else if title.kind.isAudible, let size = title.size, size > 0 {
                            Label {
                                Text(verbatim: Phrase.from("keep.audiobook.with", Formats.bytes(size)))
                            } icon: {
                                Image(systemName: "arrow.down.circle")
                            }
                        } else {
                            Label(app: "keep.keep", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var onTheGo: Bool { !network.route.largeAmountsAcceptable && network.reported }

    private func requestKeep(_ volume: AudioManifest? = nil) {
        guard let source = inventory.source(title.identifier.source) else { return }
        Haptics.selection()
        stock.requestKeep(
            title, source: source, transport: transport(title.identifier.source.provider),
            audioManifest: volume)
    }

    /// Fetches tracks and size, then the sheet opens; if the fetch fails, the shell says so
    /// and the button stays as it was.
    private func askAudiobook() {
        guard !fetchesVolume, let source = inventory.source(title.identifier.source),
            case .audioStream(let fetch) = source.content(title)
        else { return }
        fetchesVolume = true
        notices.tryRun {
            defer { fetchesVolume = false }
            do {
                audiobookQuestion = try await fetch()
            } catch {
                throw SourceError.from(error, source: title.identifier.source)
            }
        }
    }

    /// "Tidewater · 634 tracks · 608 MB", followed by the on-the-go hint if the phone is not
    /// on Wi-Fi. Without a volume only what the list knows.
    static func audiobookPhrase(_ title: Title, volume: AudioManifest?, onTheGo: Bool) -> String {
        var share = [title.name]
        if let volume { share.append(Phrase.from("keep.tracks", volume.tracks.count)) }
        if let size = volume?.size ?? title.size, size > 0 { share.append(Formats.bytes(size)) }
        var phrase = share.joined(separator: " · ")
        if onTheGo { phrase += "\n" + Phrase.from("keep.onTheGo") }
        return phrase
    }
}

/// The ring while fetching: accent on track, 16 pt.
struct KeepRing: View {

    let fraction: Double
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle().stroke(ColorTheme.muted.color.opacity(0.35), lineWidth: 2)
            Circle().trim(from: 0, to: max(fraction, 0.03))
                .stroke(theme.accent.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// The mark at the bottom right of the cover: `arrow.down.circle.fill` on a paper circle
/// when the title is on the device; the ring while it is coming; nothing for "not kept".
struct KeepMark: View {

    let identifier: TitleID
    @Environment(StockService.self) private var stock
    @Environment(\.theme) private var theme

    var body: some View {
        switch stock.entry(identifier)?.state {
        case .done:
            Image(systemName: "arrow.down.circle.fill")
                .font(.footnote)
                .foregroundStyle(theme.accent.color, theme.paper.color)
                .accessibilityLabel(Text(app: "keep.onDevice"))
        case .ongoing(let fraction, _):
            KeepRing(fraction: stock.progress(identifier)?.fraction ?? fraction)
                .padding(2)
                .background(theme.paper.color.opacity(0.85), in: Circle())
        default:
            EmptyView()
        }
    }
}

extension StockService {
    /// The mark for a row, only if the title is fully on the device.
    func rowMark(_ identifier: TitleID) -> String? {
        entry(identifier)?.done == true ? "arrow.down.circle.fill" : nil
    }
}

extension View {
    /// Without network only what is on the device is readable; everything else is dimmed,
    /// not hidden, since it can be kept once there is network. The same when only this
    /// title's source does not answer (Komga off, Grimmory there): the manga from the cache
    /// are still shown, but only the downloaded ones open.
    func dimmedWithoutNetwork(_ identifier: TitleID, available: Bool) -> some View {
        modifier(WithoutNetwork(identifier: identifier, available: available))
    }
}

private struct WithoutNetwork: ViewModifier {
    let identifier: TitleID
    let available: Bool
    @Environment(NetworkWatch.self) private var network
    @Environment(LibraryService.self) private var inventory

    private var sourceGone: Bool {
        switch inventory.failure[identifier.source] {
        case .unreachable, .serverDisruption: true
        default: false
        }
    }

    func body(content: Content) -> some View {
        let withoutNetwork = network.reported && !network.route.usable
        content.opacity((withoutNetwork || sourceGone) && !available ? 0.55 : 1)
    }
}

/// The "Keep up to volume ..." sheet: the series' volumes in order, a tap sets the limit,
/// the total below, and "Preload only at home": on the go the offline store waits until the
/// phone is on Wi-Fi.
struct KeepUntilView: View {

    let series: Series
    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock
    @Environment(NetworkWatch.self) private var network
    @Environment(\.imageTransport) private var transport
    @Environment(\.dismiss) private var close
    @State private var until: Int?

    var body: some View {
        let volumes = inventory.volumes(series.identifier)
        let unresolved = volumes.filter { stock.entry($0.identifier)?.done != true }
        let limit = until ?? min(unresolved.count, 3)
        let chosen = Array(unresolved.prefix(limit))
        let sum = chosen.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        Sheet(title: Text(appKey: Formats.lookupKey("keep.until.title", kind: series.kind))) {
            List {
                Section {
                    ForEach(Array(unresolved.enumerated()), id: \.element.id) { i, volume in
                        Button {
                            until = i + 1
                        } label: {
                            HStack {
                                Text(verbatim: Display(volume, inBookSeries: true).name)
                                    .foregroundStyle(ColorTheme.typography.color)
                                Spacer()
                                if let size = volume.size {
                                    Text(verbatim: Formats.bytes(size))
                                        .font(.footnote)
                                        .monospacedDigit()
                                        .foregroundStyle(ColorTheme.muted.color)
                                }
                                Image(systemName: i < limit ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(i < limit ? Color.accentColor : ColorTheme.muted.color)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(verbatim: series.name)
                } footer: {
                    if !network.route.largeAmountsAcceptable, network.reported {
                        Text(app: "keep.onTheGo")
                    }
                }
            }
            .listStyle(.plain)
            .paper()
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard let source = inventory.source(series.identifier.source) else { return }
                    for volume in chosen {
                        stock.requestKeep(
                            volume, source: source, transport: transport(series.identifier.source.provider))
                    }
                    Haptics.success()
                    close()
                } label: {
                    Text(
                        verbatim: Phrase.from(
                            Formats.lookupKey("keep.volumes", kind: series.kind), chosen.count,
                            Formats.bytes(sum))
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .disabled(chosen.isEmpty)
                .padding()
                .background(.bar)
            }
        }
    }
}

extension Formats {
    /// "74.5 MB".
    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file))
    }
}
