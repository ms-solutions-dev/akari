import AccountsKit
import Bedrock
import DesignSystem
import Library
import NetworkLocation
import OfflineStore
import ReadingProgress
import SourcesKit
import SwiftUI

/// The bridge from the library to the book reader: asks the server for the state
/// (conflict sheet as with comics), fetches the file into the cache ("being fetched" is
/// the only intermediate state) and builds the ``BookJob`` that the plugged-in reader
/// (``ReaderFactory``) displays.
///
/// The state goes to the library via the ``PositionReporter``: a CFI for EPUB, a page
/// for PDF; Grimmory writes both into the same progress.
struct BookReaderSheet: View {

    let title: Title

    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock
    @Environment(ReadCall.self) private var reader
    @Environment(\.imageTransport) private var transport
    @Environment(\.bookReader) private var factory
    @Environment(\.scenePhase) private var scene
    @Environment(\.dismiss) private var close
    @State private var reporter = PositionReporter()
    @Environment(ReadingTimeLog.self) private var readingTime
    @Environment(\.profileSettings) private var settings
    @State private var resolution: Resolution?
    @State private var conflict: (here: ReadingState, there: ReadingState)?
    @State private var file: URL?
    @State private var fraction: Double = 0
    @State private var bytes: Int64 = 0
    /// What the fetch failed on, as a ``SourceError`` with a sentence from the catalog;
    /// "Try again" resumes via `Range` what is already there.
    @State private var failure: SourceError?
    @State private var attempt = 0
    /// The progress bar only after 1.5 s, so a quick book opens without a spinner.
    @State private var showBar = false
    /// The book cover over the text: at 0 degrees it lies closed, at -100 degrees it is open.
    @State private var cap: Double = 0
    @State private var coverHidden = false
    @State private var coverPale = false
    @State private var glow: AdaptiveColor?
    /// The cover as the loading view loaded it; the cover shows it from the first frame.
    @State private var coverImage: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var profileTheme

    var body: some View {
        ZStack {
            // The profile's paper: with `ColorTheme.preset` the tone shifted slightly on
            // opening for anyone reading Terracotta, Indigo or Plum.
            profileTheme.paper.color.ignoresSafeArea()
            if let resolution, let file {
                if let factory {
                    factory(job(file: file, start: resolution.state))
                        .onAppear {
                            reporter.inventory = inventory
                            reporter.log = readingTime
                            reporter.settings = settings
                            unfold()
                        }
                        .onDisappear { reporter.finish() }
                        .onChange(of: scene) { _, new in if new == .background { reporter.finish() } }
                    // The cover lies over the first page as a lid and opens to the left;
                    // opening may have depth, because it happens *before* reading.
                    if !coverHidden {
                        Cover(title, width: 180, upfront: coverImage) { coverImage = $0 }
                            .environment(\.zoomSpace, nil)
                            .rotation3DEffect(
                                .degrees(cap), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.5
                            )
                            // Fade out only toward the end of the turn, not from the start.
                            // If the book has a cover, the lid only appears with the image;
                            // if the file was faster than the cover, the placeholder would
                            // otherwise show there.
                            .opacity(coverPale || (title.cover != nil && coverImage == nil) ? 0 : 1)
                            .allowsHitTesting(false)
                    }
                } else {
                    ReaderPreviewView(title: title)
                }
            } else if let failure {
                FetchFailureView(lookupKey: "book.notFetched", failure: failure) {
                    self.failure = nil
                    attempt += 1
                } close: {
                    close()
                }
            } else {
                // The cover large and calm on its glow, instead of a loading card; it is
                // the same cover that opens in a moment.
                VStack(spacing: 16) {
                    Cover(title, width: 180) { image in
                        coverImage = image
                        glow = CoverColor.glow(from: image) ?? profileTheme.accent
                    }
                    .background {
                        Glow(glow)
                            .padding(-80)
                    }
                    Text(verbatim: title.name)
                        .font(Typography.title(.title3))
                        .multilineTextAlignment(.center)
                    if showBar {
                        ProgressView(value: fraction)
                            .frame(maxWidth: 220)
                            .transition(.opacity)
                        Text(app: "book.isFetching")
                            .font(.footnote)
                            .foregroundStyle(ColorTheme.muted.color)
                            .transition(.opacity)
                    }
                    Button {
                        close()
                    } label: {
                        Text(app: "action.cancel")
                    }
                    .padding(.top, 8)
                }
                .padding(32)
                .task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(Motion.soft(reduceMotion)) { showBar = true }
                }
                // Fade away softly instead of in one frame: the glow used to vanish
                // abruptly once the reader was up.
                .transition(.opacity)
            }
        }
        .animation(Motion.soft(reduceMotion), value: resolution != nil && file != nil)
        .task(id: attempt) {
            // A second attempt only fetches the file; the state is already decided.
            guard resolution == nil || attempt > 0 else { return }
            if attempt > 0 {
                if file == nil { await fetch() }
                return
            }
            async let fetch: Void = fetch()
            let e = await inventory.decide(for: title.identifier)
            if case .question(let here, let there) = e {
                Haptics.warning()
                conflict = (here, there)
            } else {
                resolution = e
            }
            await fetch
        }
        .conflictSheet(conflict, title: title) { choice in
            guard let conflict else { return }
            switch choice {
            case .there:
                inventory.adopt(conflict.there, for: title.identifier)
                resolution = .take(conflict.there, supply: false)
            case .here:
                resolution = .take(conflict.here, supply: true)
                Task { await inventory.retain(at: conflict.here, for: title.identifier) }
            }
            self.conflict = nil
        }
        .readingHandoff(title)
    }

    /// The file: from the store if kept, otherwise into the cache.
    private func fetch() async {
        if let present = stock.files(title.identifier)?.first {
            file = present
            return
        }
        guard let source = inventory.source(title.identifier.source),
            case .file(let address, let size, let rangeCapable) = source.content(title)
        else {
            failure = .notPossible(title.identifier.source, "no file")
            return
        }
        do {
            file = try await TempFile.fetch(
                address, size: size ?? title.size, rangeCapable: rangeCapable,
                headerLines: source.headerLines(), transport: transport(title.identifier.source.provider)
            ) { b, a in
                Task { @MainActor in
                    bytes = b
                    fraction = a
                }
            }
        } catch {
            Diagnostics.network.error("Book not fetched: \(String(describing: error), privacy: .public)")
            failure = .onFetch(error, source: title.identifier.source, title: title.identifier)
        }
    }

    /// The lid opens as soon as the reader is up; with "Reduce Motion" it is simply gone.
    ///
    /// As a spring without delay: it used to wait 0.15 s, then start slowly (`easeIn`
    /// 0.6 s) and release the text only after 0.8 s. The depth was right but it felt
    /// sluggish. Now the text is free after a little over half a second.
    private func unfold() {
        guard !coverHidden else { return }
        if reduceMotion {
            coverHidden = true
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { cap = -100 }
        withAnimation(.easeOut(duration: 0.2).delay(0.28)) { coverPale = true }
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            coverHidden = true
        }
    }

    private func job(file: URL, start: ReadingState?) -> BookJob {
        let identifier = title.identifier
        let inBookSeries = title.series != nil
        let source = inventory.source(identifier.source)
        let volume: String? = title.series?.volume.map { Formats.volume($0, from: nil) }
        // The book title on top, below it the series with volume: "Sandmeer" above
        // "Sandmeer, Volume 6", not the other way round.
        let subline: String? =
            inBookSeries
            ? [title.series?.name, volume].compactMap { $0 }.joined(separator: " · ") : title.authors.first
        let reporter = reporter
        let stock = stock
        let transport = transport
        let reader = reader
        let title = title
        var toSeries: (@MainActor @Sendable () -> Void)?
        if let series = title.series {
            let target = Target.series(series.identifier)
            toSeries = { reader.jump(to: target) }
        }
        return BookJob(
            id: identifier.description,
            name: title.name,
            subline: subline,
            file: file,
            start: start?.position,
            keep: stock.completed.contains(identifier),
            report: { spot, done in
                reporter.report(spot, for: identifier, completed: done)
            },
            requestKeep: {
                guard let source else { return }
                Haptics.selection()
                stock.requestKeep(title, source: source, transport: transport(identifier.source.provider))
            },
            continuation: continuation(),
            toSeries: toSeries)
    }

    /// The next volume of the series, otherwise the first saved, unread book.
    private func continuation() -> BookJob.Continuation? {
        if let series = title.series {
            let volumes = inventory.volumes(series.identifier)
            if let i = volumes.firstIndex(where: { $0.identifier == title.identifier }), i + 1 < volumes.count
            {
                let proceed = volumes[i + 1]
                return .init(
                    kind: .nextVolume, name: proceed.name,
                    subline: proceed.series?.volume.map { Formats.volume($0, from: nil) },
                    open: { reader.open(proceed) })
            }
        }
        let saved = inventory.shelf.savedEntries.compactMap { entry -> Title? in
            if case .title(let t) = entry, t.kind == .book, t.identifier != title.identifier,
                inventory.readingState(t.identifier)?.completed != true
            {
                return t
            }
            return nil
        }
        guard let suggestion = saved.first else { return nil }
        return .init(kind: .saved, name: suggestion.name, subline: suggestion.authors.first) {
            reader.open(suggestion)
        }
    }
}
