import AccountsKit
import Bedrock
import ComicReader
import DesignSystem
import Library
import NetworkLocation
import OfflineStore
import ReadingProgress
import SourcesKit
import SwiftUI

/// The bridge from the library to the comic reader: builds the `Reader` from title, source,
/// offline store and shelf, and receives the pages the reader reports.
///
/// The reader itself knows no server. Here lives where a state goes (`PositionReporter`),
/// where the files of a kept volume come from, and which volume is next. A title that is not
/// a page stream (a Grimmory CBZ as a file) shows the notice sheet until the book reader.
struct ComicReaderSheet: View {

    let title: Title

    @Environment(LibraryService.self) private var inventory
    @Environment(StockService.self) private var stock
    @Environment(NetworkWatch.self) private var network
    @Environment(ReadCall.self) private var reader
    @Environment(\.imageTransport) private var transport
    @Environment(\.scenePhase) private var scene
    @Environment(\.dismiss) private var close
    @State private var reporter = PositionReporter()
    @Environment(ReadingTimeLog.self) private var readingTime
    @Environment(\.profileSettings) private var settings
    /// What was decided before opening; `nil` while the server is being asked.
    @State private var resolution: Resolution?
    /// The question is up; the reader waits behind it.
    @State private var conflict: (here: ReadingState, there: ReadingState)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let resolution, let volume = ribbon(title, start: resolution.state) {
                ComicReaderView(
                    volume: volume,
                    next: { [self] current in next(to: current) },
                    atHome: network.route.largeAmountsAcceptable,
                    toSeries: title.series.map { series in { reader.jump(to: .series(series.identifier)) } },
                    folder: Cache.folder.appending(path: "seiten"),
                    networkRevision: network.state
                )
                .onAppear {
                    reporter.inventory = inventory
                    reporter.log = readingTime
                    reporter.settings = settings
                }
                .onDisappear { reporter.finish() }
                // Flush on backgrounding: whatever is still pending goes out before iOS
                // freezes the app.
                .onChange(of: scene) { _, new in if new == .background { reporter.finish() } }
            } else if resolution == nil, title.kind == .manga {
                ProgressView().tint(.white)
            } else if resolution != nil {
                ReaderPreviewView(title: title)
            }
        }
        // The server is the truth: ask once before opening.
        .task {
            guard resolution == nil else { return }
            let e = await inventory.decide(for: title.identifier)
            if case .question(let here, let there) = e {
                Haptics.warning()
                conflict = (here, there)
            } else {
                resolution = e
            }
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

    private func ribbon(_ title: Title, start state: ReadingState?) -> Reader? {
        guard let source = inventory.source(title.identifier.source) else { return nil }
        let start: Int =
            if case .page(let n, _)? = state?.position { n } else { 1 }
        let inBookSeries = title.series != nil
        let number = title.series?.volume
        let identifier = title.identifier
        let count = if case .pages(let n) = title.scope { n } else { 0 }
        return Reader.from(
            source.content(title),
            id: identifier.description,
            name: inBookSeries ? title.series?.name ?? title.name : title.name,
            subline: number.map { Formats.volume($0, from: nil) } ?? (inBookSeries ? title.name : nil),
            files: stock.files(identifier),
            headerLines: source.headerLines(),
            transport: transport(identifier.source.provider),
            series: title.series?.identifier.description,
            serverDirection: title.readingDirection
                ?? title.series.flatMap { inventory.series($0.identifier)?.readingDirection },
            startPage: start,
            keep: stock.completed.contains(identifier),
            report: { [reporter] page, done in
                reporter.report(page, from: count, for: identifier, completed: done)
            },
            requestKeep: { [stock, transport] in
                Haptics.selection()
                stock.requestKeep(title, source: source, transport: transport(identifier.source.provider))
            })
    }

    /// The volume after this one in the series, for the end-of-volume sheet and preloading.
    private func next(to volume: Reader) -> Reader? {
        guard let series = title.series else { return nil }
        let volumes = inventory.volumes(series.identifier)
        guard let i = volumes.firstIndex(where: { $0.identifier.description == volume.id }),
            i + 1 < volumes.count
        else { return nil }
        let proceed = volumes[i + 1]
        return ribbon(proceed, start: inventory.readingState(proceed.identifier))
    }
}

/// The choice in the conflict sheet.
enum ConflictChoice {
    case there, here
}

extension View {
    /// The conflict sheet: "Continued elsewhere, at page 126. Last here at page 40." with two
    /// equal cards. It appears only when the server is *ahead*; everything else runs
    /// silently.
    ///
    /// A sheet instead of a dialog: the decision sat in a small box in the middle of
    /// nothing, with three identical-looking buttons. Swiping it away does not work, as with
    /// the dialog; one of the two cards must be chosen.
    func conflictSheet(
        _ conflict: (here: ReadingState, there: ReadingState)?, title: Title,
        choice: @escaping (ConflictChoice) -> Void
    ) -> some View {
        sheet(isPresented: Binding(get: { conflict != nil }, set: { _ in })) {
            if let conflict {
                ConflictSheet(here: conflict.here, there: conflict.there, choice: choice)
            }
        }
    }
}

/// The content of the conflict sheet: the question on top, below two cards, elsewhere and here.
private struct ConflictSheet: View {

    let here: ReadingState
    let there: ReadingState
    let choice: (ConflictChoice) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(app: "conflict.title")
                .font(.title3.weight(.semibold))
                .foregroundStyle(ColorTheme.typography.color)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: Phrase.from("conflict.question", Formats.long(there), Formats.long(here)))
                .font(.subheadline)
                .foregroundStyle(ColorTheme.muted.color)
                .fixedSize(horizontal: false, vertical: true)
            card(
                Phrase.from("conflict.there", Formats.short(there)), systemImage: "icloud.and.arrow.down",
                target: .there)
            card(Phrase.from("conflict.here", Formats.short(here)), systemImage: "iphone", target: .here)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .presentationBackground(theme.paper.color)
        .interactiveDismissDisabled()
    }

    private func card(_ text: String, systemImage: String, target: ConflictChoice) -> some View {
        Button {
            Haptics.selection()
            choice(target)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(theme.accent.color)
                    .frame(width: 32)
                Text(verbatim: text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ColorTheme.typography.color)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ColorTheme.muted.color)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(theme.fill.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                    theme.hairline.color, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Takes the states from the reader and writes them coalesced: the first immediately, then
/// at most every two seconds, and the last on closing, so paging through twenty pages is
/// one write, not twenty. Pages from the comic, CFIs from the book, pages from the PDF:
/// everything is a `ReadingState.Position`.
///
/// Without network the state lands in the library's queue.
@MainActor
@Observable
final class PositionReporter {

    var inventory: LibraryService?
    /// The reading-time log; `nil` or the switch off means: do not count.
    var log: ReadingTimeLog?
    /// The profile's UserDefaults, where the switch lives.
    var settings: UserDefaults = .standard
    private var pending: (spot: ReadingState.Position, identifier: TitleID, completed: Bool)?
    private var recently: Date = .distantPast
    private var planned: Task<Void, Never>?
    /// Counts reading versus paging and pauses, one per title.
    private var counter: ReadingTimeCounter?
    private var recentlySaved: Date = .distantPast
    private var last: ReadingState.Position?

    /// Minimum interval between two writes.
    static let spacing: TimeInterval = 2
    /// How often a running session goes into the log: an audiobook runs for hours, and a
    /// crash should not swallow the whole drive.
    static let saveInterval: TimeInterval = 120
    static let recordKey = "lesezeit.erfassen"

    func report(_ page: Int, from: Int, for identifier: TitleID, completed: Bool) {
        report(.page(page, from: from), for: identifier, completed: completed)
    }

    func report(_ spot: ReadingState.Position, for identifier: TitleID, completed: Bool) {
        tally(spot, for: identifier, completed: completed)
        pending = (spot, identifier, completed)
        let waitTime = PositionReporter.spacing - Date().timeIntervalSince(recently)
        if waitTime <= 0 {
            write()
        } else if planned == nil {
            planned = Task { [weak self] in
                try? await Task.sleep(for: .seconds(waitTime))
                self?.planned = nil
                self?.write()
            }
        }
    }

    /// On closing: whatever is pending goes out immediately, and the session into the log.
    func finish() {
        planned?.cancel()
        planned = nil
        if let session = counter?.finish() {
            log?.save(session)
            Diagnostics.step(
                "Reading time: \(Int(session.readingTime)) s, \(session.pages) pages, "
                    + "\(Int((session.fraction * 100).rounded())) %", since: nil, area: "Reader")
        }
        counter = nil
        write()
    }

    /// Count the reading time, if the switch is on. The kind comes from the shelf, otherwise
    /// from the shape of the position (pages: comic, CFI: book, seconds: audiobook). A
    /// session that ends after a pause goes into the log; a running one every two minutes.
    private func tally(_ spot: ReadingState.Position, for identifier: TitleID, completed: Bool) {
        guard let log, settings.object(forKey: PositionReporter.recordKey) as? Bool ?? true
        else { return }
        if counter?.identifier != identifier {
            if let closing = counter?.finish() { log.save(closing) }
            let title = inventory?.shelf.title(identifier)
            let kind =
                title?.kind
                ?? {
                    switch spot {
                    case .page: Kind.manga
                    case .second: Kind.audiobook
                    default: Kind.book
                    }
                }()
            counter = ReadingTimeCounter(
                identifier: identifier, kind: kind, name: title.map(PositionReporter.name))
        }
        let now = Date()
        if let done = counter?.report(spot, now: now, completed: completed) {
            log.save(done)
        }
        if let ongoing = counter?.ongoing,
            now.timeIntervalSince(recentlySaved) >= PositionReporter.saveInterval
        {
            log.save(ongoing)
            recentlySaved = now
        }
    }

    /// What the title should be called in the statistics when the shelf no longer knows it:
    /// by the display rule, for manga "Island Trip - Volume 47", otherwise the name as the
    /// server gives it.
    static func name(_ title: Title) -> String {
        let display = Display(title, inBookSeries: false)
        return [display.name, display.volume].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Page 3 -> 31", "40 % -> 52 %", "120 s -> 900 s": what the session achieved.
    nonisolated static func span(from: ReadingState.Position, until: ReadingState.Position) -> String {
        switch (from, until) {
        case (.page(let a, _), .page(let b, let from)): "Page \(a) → \(b) of \(from)"
        case (.second(let a, _), .second(let b, _)): "\(Int(a)) s → \(Int(b)) s"
        default: "\(percent(from)) → \(percent(until))"
        }
    }

    nonisolated private static func percent(_ spot: ReadingState.Position) -> String {
        let fraction: Double =
            switch spot {
            case .page(let n, let from): from > 0 ? Double(n) / Double(from) : 0
            case .position(_, let a), .fraction(let a): a
            case .second(let s, let from): from > 0 ? s / from : 0
            }
        return "\(Int((fraction * 100).rounded())) %"
    }

    private func write() {
        guard let (spot, identifier, completed) = pending, let inventory else { return }
        pending = nil
        last = spot
        recently = Date()
        let state = ReadingState(
            position: spot, timestamp: Date(), device: DeviceName.thisDevice, completed: completed)
        Task {
            do {
                try await inventory.write(state, for: identifier)
                Diagnostics.step(
                    "Reading state: \(PositionReporter.short(spot))\(completed ? ", completed" : "")",
                    since: nil,
                    area: "Reader")
            } catch {
                Diagnostics.network.error(
                    "Reading state not written: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func short(_ spot: ReadingState.Position) -> String {
        switch spot {
        case .page(let n, let from): "Page \(n) of \(from)"
        case .position(let cfi, let fraction): "\(cfi) (\(Int((fraction * 100).rounded())) %)"
        case .second(let s, _): "\(Int(s)) s"
        case .fraction(let a): "\(Int((a * 100).rounded())) %"
        }
    }
}
