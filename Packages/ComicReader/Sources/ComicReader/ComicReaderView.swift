import Bedrock
import DesignSystem
import PerformanceDiagnostics
import SourcesKit
import SwiftUI

/// The comic reader: always black, the page never cropped, the HUD gone after three
/// seconds.
///
/// **A horizontal scroller with page snapping**, one spread per screen; for
/// right-to-left the first page sits at the far right and the scroller starts there.
/// After the last page comes the volume-end sheet as a spread of its own - one
/// tap further, like the last page itself. The tap zones 25 / 50 / 25 are mirrored in
/// reading direction: forward is always where it continues.
///
/// **Webtoons scroll vertically** (reading direction ``ReadingDirection/vertical``, for Komga
/// `WEBTOON`): all pages one below the other at full width, without snapping and without a
/// gap. A tap there only toggles the HUD; the close drag
/// downward is locked because the same drag scrolls the strip.
///
/// **What the reader does not do:** it writes no state to a server and
/// knows no library - it reports pages to ``Reader/report``, and whoever
/// called it knows where to send them. So it stays testable on the Mac.
public struct ComicReaderView: View {

    @State private var volume: Reader
    private let nextVolume: @MainActor (Reader) -> Reader?
    private let atHome: Bool
    private let toSeries: (() -> Void)?
    private let folder: URL?
    private let presets: ReadingDefaults
    /// The network guard counter - when it rises, a different route came up, and pages that
    /// failed without network are fetched again.
    private let networkRevision: Int

    /// The slider while the thumb is on it - the target page.
    @State private var dragging: Int?
    @State private var lader: PageLoader?
    @State private var measures: [PageSize] = []
    /// What the loader measured while decoding - beats the manifest, because Komga
    /// only carries measures after its image analysis, and without them every page counts as
    /// portrait (a volume of 227 pages with none reported as landscape although the cover is one).
    @State private var measured: [Int: PageSize] = [:]
    /// Counts every change to ``measures`` and ``measured`` - the cheap trigger for
    /// ``makePlan()``, instead of comparing two plans over all pages on every rebuild.
    @State private var measureRevision = 0
    /// The plan, **computed once and kept**. It used to be a computed
    /// property: every rebuild recomputed it several times over all pages
    /// (1170 per volume), and every loaded image triggered a rebuild
    /// in the middle of the page-turn animation. On iPad that showed as stutter.
    @State private var plan = PagePlan(count: 0)
    /// An explicit jump in the webtoon (slider, keys, start) - otherwise only
    /// the finger scrolls there.
    @State private var jump: Int?
    /// Whether the jump glides (one page further) or sits at once (slider, start).
    @State private var jumpSmooth = false
    /// Whether the page measures are there - before that all webtoon pages are screen-high placeholders.
    ///
    /// **The device report**: on opening, the strip jumped to the saved page
    /// before Komga's measures arrived. Afterwards all pages shrank (800 x 1000 on iPhone: 490 instead of
    /// 852 pt), the viewport stayed put, a completely different page was on top - the position
    /// caught up, the reader rebuilt up to 126 times per second, and the reading state jumped
    /// (p. 259 -> 236). Now visibility only counts once the measures are there, and then it
    /// jumps to the page once more.
    @State private var measuresReady = false
    /// Whether the webtoon last scrolled upwards - then the window preloads upwards.
    @State private var backward = false
    /// Whether the reader has scrolled themselves - then the strip does not jump back to the page
    /// after the manifest.
    @State private var flattened = false
    /// Whether the strip has arrived at the page from opening. Before that visibility only counts
    /// when scrolled manually - otherwise the strip reported the page at the start (p. 1) as
    /// reading state before the jump to the right one had run.
    @State private var arrived = false
    /// Quietly collects what a drag did - only with diagnostics on (``DragLog``).
    @State private var dragLog = DragLog()
    /// How often the strip jumped again after opening (``jumpTo``).
    @State private var jumpCount = 0
    /// Where the webtoon strip scrolls to - pinpoint, from the ``StripLayout``.
    @State private var stripPosition = ScrollPosition(edge: .top)
    /// The pages the webtoon strip is currently building - one screen above, two below.
    @State private var shown: ClosedRange<Int> = 1...1
    /// Where the strip currently stands, without a rebuild per image (``StripState``).
    @State private var stripState = StripState()
    @State private var page: Int
    @State private var position: Int?
    @State private var hud = true
    /// The HUD clock, cancelled and restarted by ``showHud()``. After sleeping it
    /// checks `Task.isCancelled`: a cancelled `Task.sleep` returns at once,
    /// and without the check the old clock hid the HUD that had just been shown at the same
    /// moment (same as in the book reader).
    @State private var hudClock = 0
    /// The menu is open - the HUD stays up meanwhile.
    @State private var menuOpen = false
    @State private var direction: ReadingDirection
    @State private var doubleSpread: Bool
    /// The width of the webtoon strip, as a fraction of the screen width - saved per series.
    @State private var column: Double
    /// The running two-finger drag, multiplied with ``column``; 1 while none is running.
    @State private var breadcrumb: Double = 1
    @State private var wideEnough = false
    @State private var size: CGSize = .zero
    /// How far the page follows when dragging down.
    @State private var toast = false
    @State private var toastShown = false
    @State private var nextLoader: PageLoader?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var calm

    /// How long the HUD stays after the last tap.
    static let hudDuration: Duration = .seconds(3)
    /// From when a page counts as "slow" and the toast appears - four seconds is
    /// never on a LAN and always through the tunnel at 700 kB.
    static let slowFrom: TimeInterval = 4
    /// From this width a double spread works in landscape - on iPhone too
    /// ("two pages side by side when landscape, like in print, panels work that way too");
    /// in split view on iPad (under 600 pt) it stays the single page.
    static let doubleSpreadFrom: CGFloat = 600

    /// - Parameters:
    ///   - volume: what is read
    ///   - next: the volume after it - for the volume-end sheet and preloading
    ///   - atHome: large amounts acceptable - then 5 pages ahead and the next volume
    ///   - toSeries: "Show series" in the menu and at the volume end; `nil` without a series
    ///   - folder: the cache for pages; `nil` keeps nothing on disk
    ///   - presets: the store for direction and double spread per series
    ///   - networkRevision: the network guard counter - every change refetches failed pages
    public init(
        volume: Reader, next: @escaping @MainActor (Reader) -> Reader? = { _ in nil },
        atHome: Bool = true, toSeries: (() -> Void)? = nil, folder: URL? = nil,
        presets: ReadingDefaults = ReadingDefaults(), networkRevision: Int = 0
    ) {
        _volume = State(initialValue: volume)
        self.nextVolume = next
        self.atHome = atHome
        self.toSeries = toSeries
        self.folder = folder
        self.presets = presets
        self.networkRevision = networkRevision
        _page = State(initialValue: volume.startPage)
        _position = State(initialValue: volume.startPage)
        var chosen = presets.direction(series: volume.series, server: volume.serverDirection)
        #if DEBUG
            // `AKARI_RICHTUNG=vertikal`: the webtoon strip for a screenshot. Debug builds only.
            if ProcessInfo.processInfo.environment["AKARI_RICHTUNG"] == "vertikal" { chosen = .vertical }
        #endif
        _direction = State(initialValue: chosen)
        _doubleSpread = State(initialValue: presets.doubleSpread(series: volume.series))
        _column = State(initialValue: presets.width(series: volume.series))
    }

    private var vertical: Bool { direction == .vertical }

    /// The width of the webtoon strip including the running drag. Near 100 % it snaps -
    /// otherwise full width is never hit exactly with two fingers.
    private var factor: Double {
        let raw = min(
            max(column * breadcrumb, ReadingDefaults.widths.lowerBound), ReadingDefaults.widths.upperBound)
        return abs(raw - 1) < 0.05 ? 1 : raw
    }

    /// What goes into the plan - as a trigger for ``makePlan()``.
    private struct PlanInput: Equatable {
        let count: Int
        let measureRevision: Int
        let doubleSpread: Bool
        let direction: ReadingDirection
    }

    private var planInput: PlanInput {
        PlanInput(
            count: volume.count, measureRevision: measureRevision,
            doubleSpread: doubleSpread && wideEnough && !vertical,
            direction: direction)
    }

    /// Recomputes the plan. Rotating or switching: the page stays, the spread
    /// changes. **The webtoon does not catch up** - there the spread is the page
    /// itself, and setting the position pulled the strip back to the start of the page
    /// with every image loaded afterwards ("keeps jumping back a bit").
    private func makePlan() {
        let input = planInput
        let startTime = ContinuousClock.now
        let new = PagePlan(
            count: input.count,
            measures: PagePlan.merged(measures, measured: measured, count: input.count),
            doubleSpread: input.doubleSpread, direction: input.direction)
        Performance.measure("Plan computed ms", (ContinuousClock.now - startTime).milliseconds)
        plan = new
        guard !vertical, position != end, let target = new.spread(with: page)?.first, target != position
        else { return }
        position = target
    }

    /// A measured image - **only if it says something new.** Before, every
    /// loaded image went into state, even when Komga had long delivered the same measure; each
    /// was a rebuild of the whole reader.
    private func save(_ page: Int, _ mass: PageSize) {
        guard measured[page] != mass, PagePlan.worthMetering(mass, page: page, manifest: measures) else {
            return
        }
        measured[page] = mass
        measureRevision += 1
        Performance.measure("Dimensions re-measured", 1)
    }

    /// The identifier of the volume-end sheet in the scroller.
    private var end: Int { volume.count + 1 }

    private var sheets: [Sheet] {
        let pages = plan.flattened.map(Sheet.spread)
        return direction == .rightToLeft ? [.end(end)] + pages : pages + [.end(end)]
    }

    private var next: Reader? { nextVolume(volume) }

    /// The state as numbers for diagnostics - which value drove a rebuild is then in
    /// the report ("scaleRevision x80, page x20, external x26"). Only computed while
    /// recording.
    private var snapshot: [String: Int] {
        [
            "page": page, "position": position ?? -1, "scale": measureRevision,
            "gemessen": measured.count,
            "masse": measures.count, "plan": plan.spreads.count, "hud": hud ? 1 : 0, "hudUhr": hudClock,
            "menueOffen": menuOpen ? 1 : 0, "toast": toast ? 1 : 0, "zug": Int(breadcrumb * 1000),
            "spalte": Int(column * 1000), "masseBereit": measuresReady ? 1 : 0,
            "rueckwaerts": backward ? 1 : 0,
            "arrived": arrived ? 1 : 0, "flattened": flattened ? 1 : 0, "jump": jump ?? -1,
            "ziehen": dragging ?? -1, "lader": lader == nil ? 0 : 1, "breite": Int(size.width),
            "height": Int(size.height), "wideEnough": wideEnough ? 1 : 0, "volume": volume.id.hashValue,
            "richtung": direction.hashValue, "doppelseite": doubleSpread ? 1 : 0,
        ]
    }

    public var body: some View {
        let _ = Performance.build("Comic reader") { snapshot }
        // The GeometryReader measures INSIDE the safe area, and the rest adds the
        // margins back: in landscape the iPhone takes 59 pt off left and right, but the
        // scroller snaps at full width - every page would otherwise be 118 pt
        // narrower than a snap step. Letting the reader itself ignore the safe
        // area reports margins of zero, and the close button
        // sits in the status bar. HUD and toast respect the margins,
        // the pages fill everything.
        GeometryReader { geo in
            let margin = geo.safeAreaInsets
            let full = CGSize(
                width: geo.size.width + margin.leading + margin.trailing,
                height: geo.size.height + margin.top + margin.bottom)
            ZStack {
                Color.black
                if vertical {
                    webtoonStrip(full)
                } else {
                    roller(full)
                }
                hudLayer(margin)
                toastLayer(margin)
            }
            .ignoresSafeArea()
            // Measured via the geometry query, not via `onChange` on the
            // closure value: it does not fire reliably on rotation, and the reader
            // stayed on a single page in landscape.
            .onGeometryChange(for: CGSize.self) { proxy in
                let margin = proxy.safeAreaInsets
                return CGSize(
                    width: proxy.size.width + margin.leading + margin.trailing,
                    height: proxy.size.height + margin.top + margin.bottom)
            } action: { new in
                measure(new)
            }
            .onAppear { measure(full) }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(hud ? .automatic : .hidden)
        .keepAwake()
        .statusStrip(hidden: !hud)
        .preference(key: CloseGestureLocked.self, value: vertical)
        .task(id: volume.id) { await open() }
        // Paging test without a finger (simulator): AKARI_BLAETTERPROBE=<seconds>
        // pages forward at that interval - for the fault test that wants to see what
        // the reader shows when the network drops mid-volume.
        .task {
            guard let beat = Double(ProcessInfo.processInfo.environment["AKARI_BLAETTERPROBE"] ?? "")
            else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(beat))
                guard !Task.isCancelled else { return }
                turnPage(.before)
            }
        }
        .task(id: hudClock) {
            guard hud, !menuOpen else { return }
            try? await Task.sleep(for: ComicReaderView.hudDuration)
            guard !Task.isCancelled, !menuOpen else { return }
            withAnimation(Motion.soft(calm)) { hud = false }
        }
        .onChange(of: menuOpen) { _, unresolved in if !unresolved { hudClock += 1 } }
        .onChange(of: position) { _, new in
            guard let new else { return }
            if new == end {
                volume.report(volume.count, true)
            } else if plan.spread(with: new) != nil {
                page = new
                Performance.spot(
                    "S. \(new)/\(volume.count)\(vertical ? " (Webtoon \(Int((factor * 100).rounded())) %)" : "")"
                )
                volume.report(new, new >= volume.count || plan.spread(with: new)?.last == volume.count)
            }
            preload()
        }
        .onChange(of: planInput, initial: true) { _, _ in makePlan() }
        .onKeyPress(.leftArrow) {
            turnPage(direction == .rightToLeft ? .before : .back); return .handled
        }
        .onKeyPress(.rightArrow) {
            turnPage(direction == .rightToLeft ? .back : .before); return .handled
        }
        .onKeyPress(.upArrow) {
            guard vertical else { return .ignored }
            turnPage(.back); return .handled
        }
        .onKeyPress(.downArrow) {
            guard vertical else { return .ignored }
            turnPage(.before); return .handled
        }
        .accessibilityAction(named: Text(app: "reader.nextPage")) { turnPage(.before) }
        .accessibilityAction(named: Text(app: "reader.previousPage")) { turnPage(.back) }
    }

    // MARK: - The scroller

    private func roller(_ size: CGSize) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(sheets) { sheet in
                    Group {
                        switch sheet {
                        case .spread(let spread):
                            spreadView(spread, width: size.width)
                        case .end:
                            VolumeEndSheet(
                                volume: volume, next: next, toSeries: toSeries,
                                proceed: { proceed in switchTo(to: proceed) }, dismiss: { dismiss() })
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .id(sheet.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // On rotation the scroller is rebuilt and jumps to the saved
        // page: a spread is suddenly twice as wide, but the point offset of the
        // scroller is the same. The images are in the loader's memory and appear
        // again immediately.
        .id(Int(size.width))
    }

    /// The webtoon strip: each page at the width of the strip, as tall as its measure says -
    /// without a measure as tall as the screen until the image arrives. The scroll position is
    /// the page that touches the top; it is the reading state.
    ///
    /// **Two fingers make the strip narrower or wider** (25-200 %):
    /// narrower it sits centered on black, wider it also scrolls sideways.
    /// The scroller is therefore always two-axis; as long as the strip is not wider than the
    /// screen there is nothing to scroll sideways.
    private func webtoonStrip(_ size: CGSize) -> some View {
        let merged = PagePlan.merged(measures, measured: measured, count: volume.count)
        let pageWidth = (size.width * factor).rounded()
        let layout = StripLayout(
            heights: (0..<max(volume.count, 1)).map { i in
                height(i < merged.count ? merged[i] : nil, width: pageWidth, otherwise: size.height)
            })
        let stripWidth = max(pageWidth, size.width)
        let visible = shown.clamped(to: 1...max(layout.count, 1))
        return Group {
            ScrollView([.vertical, .horizontal]) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(visible), id: \.self) { s in
                        WebtoonPage(
                            page: s, lader: lader, current: abs(s - page) <= 1,
                            networkRevision: networkRevision,
                            slow: { duration in slow(duration) },
                            measured: { mass in save(s, mass) }
                        )
                        .frame(width: pageWidth, height: layout.height(s))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: Wording.phrase("reader.pageOf", s, volume.count)))
                        .offset(x: (stripWidth - pageWidth) / 2, y: layout.topEdge(s))
                    }
                    VolumeEndSheet(
                        volume: volume, next: next, toSeries: toSeries,
                        proceed: { proceed in switchTo(to: proceed) }, dismiss: { dismiss() }
                    )
                    .frame(width: size.width, height: size.height)
                    .offset(x: (stripWidth - size.width) / 2, y: layout.totalHeight)
                }
                .frame(width: stripWidth, height: layout.totalHeight + size.height, alignment: .topLeading)
            }
            .scrollPosition($stripPosition)
            .onScrollGeometryChange(for: StripViewport.self) { geometry in
                StripViewport(top: geometry.visibleRect.minY, offset: geometry.contentOffset.y)
            } action: { _, viewport in
                stripRolled(viewport, layout: layout, height: size.height)
            }
            .onScrollPhaseChange { _, phase, _ in
                if phase == .interacting { flattened = true }
                guard Performance.records else { return }
                let word = ComicReaderView.phaseWord(phase)
                Performance.scroll(word, "top p. \(position ?? page)")
                if let text = dragLog.phase(
                    word, page: position ?? page, time: ProcessInfo.processInfo.systemUptime)
                {
                    Performance.breadcrumb(text)
                }
            }
            .onChange(of: jump) { _, target in
                guard let target else { return }
                let y = target > layout.count ? layout.totalHeight : layout.topEdge(target)
                stripState.target(page: target)
                shown = ComicReaderView.visibleRange(layout, top: y, height: size.height, soFar: nil)
                if jumpSmooth {
                    withAnimation(Motion.short(calm)) { stripPosition.scrollTo(y: y - stripState.indent) }
                } else {
                    stripPosition.scrollTo(y: y - stripState.indent)
                }
                jump = nil
                Performance.remark("Jump to p. \(target) — point \(Int(y))")
            }
            // A new width (two fingers) or a late measure shifts all pages
            // below: the same spot stays at the top instead of the strip slipping away.
            .onChange(of: layout) { _, new in
                let y = new.point(page: stripState.page, fraction: stripState.fraction)
                shown = ComicReaderView.visibleRange(new, top: y, height: size.height, soFar: nil)
                stripPosition.scrollTo(y: y - stripState.indent)
            }
            .onAppear {
                stripState.target(page: page)
                let y = layout.topEdge(page)
                shown = ComicReaderView.visibleRange(layout, top: y, height: size.height, soFar: nil)
                stripPosition.scrollTo(y: y)
            }
            .defaultScrollAnchor(.top)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollIndicators(.hidden)
            .contentShape(Rectangle())
            .onTapGesture {
                if hud {
                    withAnimation(Motion.soft(calm)) { hud = false }
                } else {
                    showHud()
                }
            }
            // **Dragging left to right closes**: the downward drag
            // scrolls the strip here, so the sideways one closes. Only at full width -
            // when dragged wider the sideways swipe is needed for panning. Alongside scrolling,
            // so a vertical swipe stays a swipe; only what is clearly horizontal counts.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onChanged { value in
                        guard Performance.records else { return }
                        if let previous = dragLog.finger(
                            start: value.startLocation, route: value.translation,
                            time: ProcessInfo.processInfo.systemUptime, page: position ?? page)
                        {
                            Performance.breadcrumb(previous)
                        }
                    }
                    .onEnded { breadcrumb in
                        if Performance.records,
                            let text = dragLog.fingerEnd(
                                page: position ?? page, time: ProcessInfo.processInfo.systemUptime)
                        {
                            Performance.breadcrumb(text)
                        }
                        guard factor <= 1, ComicReaderView.closesWebtoon(breadcrumb.translation) else {
                            return
                        }
                        dismiss()
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in breadcrumb = value.magnification }
                    .onEnded { _ in
                        column = factor
                        breadcrumb = 1
                        if let series = volume.series { presets.set(width: column, series: series) }
                    }
            )
            .overlay(alignment: .top) {
                if breadcrumb != 1 {
                    Text(verbatim: "\(Int((factor * 100).rounded())) %")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.16), in: Capsule())
                        .padding(.top, 60)
                        .allowsHitTesting(false)
                }
            }
        }
        .id(Int(size.width))
    }

    /// Whether a drag in the webtoon means closing: at least ``closeDragFrom`` to the right and
    /// at least twice as far horizontally as vertically - otherwise it was scrolling.
    nonisolated static func closesWebtoon(_ route: CGSize) -> Bool {
        route.width >= closeDragFrom && abs(route.height) * 2 <= route.width
    }

    /// So far to the right until the webtoon closes.
    nonisolated static let closeDragFrom: CGFloat = 110

    /// The scroll phase as a word for diagnostics.
    nonisolated static func phaseWord(_ phase: ScrollPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .tracking: "touched"
        case .interacting: "finger"
        case .decelerating: "coasting"
        case .animating: "springt"
        @unknown default: "?"
        }
    }

    /// The height of a webtoon page at the strip width - without a measure `otherwise`.
    private func height(_ mass: PageSize?, width: CGFloat, otherwise: CGFloat) -> CGFloat {
        guard let mass, mass.width > 0, mass.height > 0 else { return otherwise }
        return (width * CGFloat(mass.height) / CGFloat(mass.width)).rounded()
    }

    private func spreadView(_ spread: Spread, width: CGFloat) -> some View {
        SpreadView(
            pages: pagesInRow(spread), lader: lader, current: spread.contains(page),
            networkRevision: networkRevision,
            tip: { x in tip(x: x, width: width) },
            slow: { duration in slow(duration) },
            measured: { s, mass in save(s, mass) }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Wording.phrase("reader.pageOf", spread.first, volume.count)))
    }

    /// Left to right on screen - for a double spread already resolved.
    private func pagesInRow(_ spread: Spread) -> [Int] {
        switch spread {
        case .single(let s): [s]
        case .double(let l, let r): [l, r]
        }
    }

    // MARK: - HUD

    private func hudLayer(_ margin: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            if hud {
                header
                    .padding(.top, margin.top)
                    .padding(.leading, margin.leading)
                    .padding(.trailing, margin.trailing)
                    .background(Color.black.opacity(0.78))
                    .transition(.move(edge: .top).combined(with: .opacity))
                Spacer()
                footer
                    .padding(.bottom, margin.bottom)
                    .padding(.leading, margin.leading)
                    .padding(.trailing, margin.trailing)
                    .background(Color.black.opacity(0.78))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(hud)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(app: "action.close"))
            VStack(spacing: 2) {
                Text(verbatim: volume.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subline = volume.subline {
                    Text(verbatim: subline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            menu
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var menu: some View {
        Menu {
            // The menu items appear on opening and vanish on closing -
            // `menuOpen` depends on that; SwiftUI does not report it otherwise.
            Picker(selection: directionChoice) {
                Text(app: "reader.direction.auto").tag(ReadingDirection?.none)
                Text(app: "reader.direction.rtl").tag(ReadingDirection?.some(.rightToLeft))
                Text(app: "reader.direction.ltr").tag(ReadingDirection?.some(.leftToRight))
                Text(app: "reader.direction.vertical").tag(ReadingDirection?.some(.vertical))
            } label: {
                Label(app: "reader.direction", systemImage: "arrow.left.arrow.right")
            }
            .pickerStyle(.menu)
            .onAppear { menuOpen = true }
            .onDisappear { menuOpen = false }
            if vertical, column != 1 {
                Button {
                    column = 1
                    if let series = volume.series { presets.set(width: 1, series: series) }
                    showHud()
                } label: {
                    Label(app: "reader.resetWidth", systemImage: "arrow.left.and.right")
                }
            }
            if wideEnough, !vertical {
                Toggle(isOn: doubleSpreadChoice) {
                    Label(app: "reader.doubleSpread", systemImage: "book")
                }
            }
            Divider()
            Button {
                jump(to: 1)
            } label: {
                Label(app: "reader.toStart", systemImage: "backward.end")
            }
            if let toSeries {
                Button {
                    dismiss()
                    toSeries()
                } label: {
                    Label(app: "menu.series", systemImage: "books.vertical")
                }
            }
            if !volume.keep {
                Button {
                    volume.requestKeep()
                } label: {
                    Label(app: "reader.keepVolume", systemImage: "arrow.down.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(app: "reader.menu"))
    }

    private var directionChoice: Binding<ReadingDirection?> {
        Binding {
            volume.series.flatMap { presets.direction(series: $0) }
        } set: { new in
            if let series = volume.series { presets.set(direction: new, series: series) }
            let was = vertical
            withAnimation(Motion.short(calm)) {
                direction = new ?? presets.direction(series: nil, server: volume.serverDirection)
            }
            // The webtoon downscales by width, paging by the longer edge.
            if was != vertical {
                lader = nil
                makeLoader()
            }
            showHud()
        }
    }

    private var doubleSpreadChoice: Binding<Bool> {
        Binding {
            doubleSpread
        } set: { new in
            if let series = volume.series { presets.set(doubleSpread: new, series: series) }
            withAnimation(Motion.short(calm)) { doubleSpread = new }
            showHud()
        }
    }

    /// The slider only jumps on release - as in the player; while dragging the
    /// row shows the target page (before: a page fetch per step).
    private var footer: some View {
        VStack(spacing: 6) {
            Text(verbatim: Wording.phrase("reader.pageOf", dragging ?? page, volume.count))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.white)
            Slider(
                value: Binding(
                    get: { Double(dragging ?? page) },
                    set: { new in
                        dragging = Int(new.rounded())
                        showHud()
                    }),
                in: 1...Double(volume.count), step: 1,
                onEditingChanged: { active in
                    if !active, let target = dragging {
                        jump(to: target)
                        dragging = nil
                    }
                }
            )
            .tint(.white)
            .frame(minHeight: TapTarget.atLeast)
            // For right-to-left the slider runs from right to left -
            // like the pages themselves.
            .environment(\.layoutDirection, direction == .rightToLeft ? .rightToLeft : .leftToRight)
            .accessibilityLabel(Text(app: "reader.page"))
            .accessibilityValue(Text(verbatim: Wording.phrase("reader.pageOf", page, volume.count)))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Toast

    private func toastLayer(_ margin: EdgeInsets) -> some View {
        VStack {
            Spacer()
            if toast {
                HStack(spacing: 12) {
                    Text(app: "reader.slow")
                        .font(.footnote)
                        .foregroundStyle(.white)
                    Button {
                        volume.requestKeep()
                        withAnimation(Motion.short(calm)) { toast = false }
                    } label: {
                        Text(app: "reader.keepVolume")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, (hud ? 96 : 24) + margin.bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation(Motion.soft(calm)) { toast = false }
                }
            }
        }
    }

    // MARK: - Drag to close

    /// Dragging down closes the reader - the drag comes from outside (`CloseGesture` of the
    /// shell, as for book and audiobook): the whole layer follows the finger, the app is visible below
    /// it, and it exits with the momentum. Before, it lived here, with an opacity on
    /// the image layer per frame and a system exit from standstill.

    // MARK: - Behavior

    private func measure(_ new: CGSize) {
        size = new
        let wide = new.width > new.height && new.width >= ComicReaderView.doubleSpreadFrom
        Diagnostics.step(
            "Reader measures \(Int(new.width)) × \(Int(new.height)), double spread \(wide && doubleSpread ? "on" : "off")",
            since: nil, area: "Reader")
        if wide != wideEnough { wideEnough = wide }
        if lader == nil { makeLoader() }
    }

    /// The loader needs the screen edge - hence only after the first measurement.
    private func makeLoader() {
        guard size.width > 0 else { return }
        lader = PageLoader(
            count: volume.count, address: volume.address, files: volume.files,
            headerLines: volume.headerLines,
            transport: volume.transport, folder: folder,
            // In the webtoon up to half the width above that - whoever drags the strip to 150 %
            // should not see an upscaled page. Nothing is enlarged beyond the original.
            pixels: Int((vertical ? size.width * 1.5 : max(size.width, size.height)) * scale),
            byWidth: vertical)
        preload()
    }

    private func open() async {
        toastShown = volume.keep
        nextLoader = nil
        if let fetch = volume.measures, measures.isEmpty {
            let persistence = folder.map { MeasureStore(folder: $0, volume: volume) }
            if let saved = persistence?.restoreFromDisk(), saved.count == volume.count {
                // From last time: the right heights at once, without waiting for the server.
                measures = saved
                measureRevision += 1
                readyAndJump()
                if let fresh = try? await fetch(), fresh != saved {
                    measures = fresh
                    measureRevision += 1
                    persistence?.write(fresh)
                }
                return
            }
            measures = (try? await fetch()) ?? []
            measureRevision += 1
            if !measures.isEmpty { persistence?.write(measures) }
            let landscape = measures.enumerated().filter { $0.element.landscape }.map { $0.offset + 1 }
            Diagnostics.step(
                "Manifest: \(measures.count) pages, landscape: \(landscape.map(String.init).joined(separator: " "))",
                since: nil, area: "Reader")
        }
        readyAndJump()
    }

    /// The strip moved: remember the state (without a rebuild), top up the built pages
    /// when the spot leaves the stock, and report the topmost page as reading state.
    private func stripRolled(_ viewport: StripViewport, layout: StripLayout, height: CGFloat) {
        stripState.indent = viewport.top - viewport.offset
        if Performance.records {
            dragLog.offset(viewport.offset, time: ProcessInfo.processInfo.systemUptime)
        }
        let area = ComicReaderView.visibleRange(layout, top: viewport.top, height: height, soFar: shown)
        if area != shown { shown = area }
        let top = layout.page(at: viewport.top + 1)
        if arrived || flattened { stripState.save(layout.fraction(at: viewport.top)) }
        guard measuresReady, top != position else { return }
        if !arrived {
            guard flattened || abs(top - page) <= 2 else {
                jumpTo(top)
                return
            }
            arrived = true
            stripState.save(layout.fraction(at: viewport.top))
        }
        if let old = position, old <= volume.count { backward = top < old }
        position = top
    }

    /// Which pages should be built: what lies between a quarter screen above and
    /// one and a half below must stand; a new choice is only made when that no longer
    /// holds - then one screen above, two below. So the strip does not rebuild on every
    /// image, but about once per screen.
    nonisolated static func visibleRange(
        _ layout: StripLayout, top y: CGFloat, height: CGFloat, soFar: ClosedRange<Int>?
    ) -> ClosedRange<Int> {
        let needed = layout.pages(from: y - height * 0.25, until: y + height * 1.5)
        if let soFar, soFar.contains(needed.lowerBound), soFar.contains(needed.upperBound) {
            return soFar
        }
        return layout.pages(from: y - height, until: y + height * 2)
    }

    /// **The jump lands next to it**: the
    /// LazyVStack estimates the height of pages it has not built yet, and a long series has
    /// a landscape page of different height every ten pages - by page 520 that adds up to ten
    /// pages. The reader saw 531, the state said 520, and the first drag jumped. If visibility
    /// reports another page and nothing was scrolled yet, the strip jumps once more;
    /// then the pages around it stand and the jump sits. At most three times.
    private func jumpTo(_ landed: Int) {
        guard vertical, !flattened, jumpCount < 3, jump == nil else { return }
        jumpCount += 1
        Performance.remark("Jump landed on p. \(landed) instead of \(page) — follow-up jump \(jumpCount)")
        jumpSmooth = false
        jump = page
    }

    /// The measures are there: visibility counts from now on, and the strip jumps to the page once more with the
    /// right heights - the first jump lay on placeholders.
    /// **Not if already scrolled:**
    /// the jump tore the strip back to the page from opening.
    private func readyAndJump() {
        measuresReady = true
        guard vertical, !flattened else { return }
        jumpSmooth = false
        jump = page
    }

    private func tip(x: CGFloat, width: CGFloat) {
        switch TapZone.for(x: x, width: width, direction: direction) {
        case .before: turnPage(.before)
        case .back: turnPage(.back)
        case .hud:
            if hud {
                withAnimation(Motion.soft(calm)) { hud = false }
            } else {
                showHud()
            }
        }
    }

    private func showHud() {
        withAnimation(Motion.soft(calm)) { hud = true }
        hudClock += 1
    }

    private func turnPage(_ zone: TapZone) {
        let plan = plan
        if position == end {
            guard zone == .back, let latest = plan.spreads.last else { return }
            go(to: latest.first, soft: true)
            return
        }
        guard let current = plan.spread(with: page) else { return }
        let target: Int? =
            switch zone {
            case .before: plan.next(to: current)?.first ?? end
            case .back: plan.previous(before: current)?.first
            case .hud: nil
            }
        guard let target else { return }
        go(to: target, soft: true)
    }

    /// In the scroller via the bound position, in the webtoon via ``jump`` - there the
    /// position is only a display of what is on top.
    private func go(to target: Int, soft: Bool) {
        if vertical {
            jumpSmooth = soft
            jump = target
        } else if soft {
            withAnimation(Motion.short(calm)) { position = target }
        } else {
            position = target
        }
    }

    private func jump(to new: Int) {
        guard let spread = plan.spread(with: min(max(new, 1), volume.count)) else { return }
        page = spread.first
        go(to: spread.first, soft: false)
    }

    /// The "On the way" toast from ``slowFrom``; the diagnostics note is written by the loader itself,
    /// with source, decode duration and queue.
    private func slow(_ duration: TimeInterval) {
        guard duration >= ComicReaderView.slowFrom, !toastShown, !volume.keep else { return }
        toastShown = true
        withAnimation(Motion.soft(calm)) { toast = true }
    }

    private func preload() {
        guard let lader else { return }
        let window = Preload.window(
            around: page, count: volume.count, atHome: atHome, vertical: vertical, backward: backward,
            width: factor)
        let center = page
        Task { await lader.preload(window, around: center) }
        let upfront = Preload.nextVolume(page: page, count: volume.count, atHome: atHome)
        if upfront > 0, nextLoader == nil, let proceed = next, proceed.files == nil {
            let l = PageLoader(
                count: proceed.count, address: proceed.address, headerLines: proceed.headerLines,
                transport: proceed.transport, folder: folder, pixels: 64)
            nextLoader = l
            Task { await l.preload(1...min(upfront, proceed.count)) }
        }
    }

    /// "Keep reading" at the volume end: the same reader, the next volume.
    private func switchTo(to proceed: Reader) {
        lader = nil
        measures = []
        measured = [:]
        measuresReady = false
        flattened = false
        backward = false
        arrived = false
        jumpCount = 0
        measureRevision += 1
        volume = proceed
        direction = presets.direction(series: proceed.series, server: proceed.serverDirection)
        doubleSpread = presets.doubleSpread(series: proceed.series)
        column = presets.width(series: proceed.series)
        page = 1
        position = 1
        toastShown = proceed.keep
        nextLoader = nil
        makeLoader()
        showHud()
    }
}

/// A sheet in the scroller: a spread or the volume end (identifier `count + 1`).
private enum Sheet: Identifiable, Hashable {
    case spread(Spread)
    case end(Int)

    var id: Int {
        switch self {
        case .spread(let a): a.first
        case .end(let identifier): identifier
        }
    }
}

/// A spread: one or two sheets on a stage, a spinner each while
/// a sheet is still coming; the tap zones also work without an image.
///
/// **A page that did not arrive does not stay lying there**:
/// as long as the spread is the one shown, it tries again every ``repeatFrom``
/// seconds, a tap on "Try again" at once, and a change of the
/// network route (`networkRevision`) too - if the network drops mid-volume, the page
/// stays, and as soon as it is back, paging continues. Before, it said "Page not
/// loaded" until the volume was closed and reopened.
///
/// **`current` does not restart the task**: it used to be in the identifier of the
/// task, and when a spread became the shown one while its image was still coming, SwiftUI
/// cancelled the running task and started over - the loader lost its last waiter,
/// the download dropped, a new one began (same page three times with 1.7, 2.0 and
/// 2.2 s). Now `current` only triggers the retry of a failed page.
private struct SpreadView: View {

    let pages: [Int]
    let lader: PageLoader?
    let current: Bool
    let networkRevision: Int
    let tip: (CGFloat) -> Void
    let slow: (TimeInterval) -> Void
    let measured: (Int, PageSize) -> Void

    @State private var images: [Int: PageImage] = [:]
    @State private var failedPages: Set<Int> = []
    @State private var attempt = 0

    /// How long to wait after a failure before the shown page is fetched
    /// once more.
    static let repeatFrom: Duration = .seconds(5)

    var body: some View {
        ZStack {
            Color.black
            ZoomImage(images: pages.map { images[$0]?.image }, current: current, tip: tip)
            HStack(spacing: 0) {
                ForEach(pages, id: \.self) { s in
                    ZStack {
                        if images[s] == nil {
                            if failedPages.contains(s) {
                                VStack(spacing: 10) {
                                    Image(systemName: "wifi.exclamationmark")
                                        .font(.title2)
                                    Text(app: "reader.pageMissing")
                                        .font(.footnote)
                                    Button {
                                        attempt += 1
                                    } label: {
                                        Text(app: "reader.pageAgain")
                                            .font(.footnote.weight(.semibold))
                                            .padding(.horizontal, 14)
                                            .frame(minHeight: TapTarget.atLeast)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.white)
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(failedPages.contains(s))
                }
            }
        }
        .task(
            id: TaskKey(pages: pages, lader: lader != nil, networkRevision: networkRevision, attempt: attempt)
        ) {
            guard let lader else { return }
            failedPages = []
            // Fetch both sheets side by side - the left does not wait for the right.
            await withTaskGroup(of: (Int, PageImage?).self) { cluster in
                for s in pages where images[s] == nil {
                    cluster.addTask { (s, await lader.image(s)) }
                }
                for await (s, image) in cluster {
                    guard !Task.isCancelled else { return }
                    if let image {
                        images[s] = image
                        measured(s, PageSize(width: image.width, height: image.height))
                        if let duration = image.duration { slow(duration) }
                    } else {
                        failedPages.insert(s)
                    }
                }
            }
            guard current, !failedPages.isEmpty else { return }
            try? await Task.sleep(for: SpreadView.repeatFrom)
            guard !Task.isCancelled else { return }
            attempt += 1
        }
        .onChange(of: current) { _, now in
            if now, !failedPages.isEmpty { attempt += 1 }
        }
    }

    private struct TaskKey: Equatable {
        let pages: [Int]
        let lader: Bool
        let networkRevision: Int
        let attempt: Int
    }
}

/// A page in the webtoon strip: the image at full width, a spinner while it
/// is coming, and the same retry as ``SpreadView`` if it did not arrive.
/// No zooming here - the strip scrolls under the finger.
///
/// `current` is not in the task identifier for the same reason as there: while
/// scrolling every page becomes "current" once, exactly when its image is arriving.
private struct WebtoonPage: View {

    let page: Int
    let lader: PageLoader?
    let current: Bool
    let networkRevision: Int
    let slow: (TimeInterval) -> Void
    let measured: (PageSize) -> Void

    @State private var image: PageImage?
    @State private var failedPages = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else if failedPages {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title2)
                    Text(app: "reader.pageMissing")
                        .font(.footnote)
                    Button {
                        attempt += 1
                    } label: {
                        Text(app: "reader.pageAgain")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: TapTarget.atLeast)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: TaskKey(lader: lader != nil, networkRevision: networkRevision, attempt: attempt)) {
            guard let lader, image == nil else { return }
            failedPages = false
            if let fetched = await lader.image(page) {
                guard !Task.isCancelled else { return }
                image = fetched
                measured(PageSize(width: fetched.width, height: fetched.height))
                if let duration = fetched.duration { slow(duration) }
                return
            }
            guard !Task.isCancelled else { return }
            failedPages = true
            guard current else { return }
            try? await Task.sleep(for: SpreadView.repeatFrom)
            guard !Task.isCancelled else { return }
            attempt += 1
        }
        .onChange(of: current) { _, now in
            if now, failedPages { attempt += 1 }
        }
    }

    private struct TaskKey: Equatable {
        let lader: Bool
        let networkRevision: Int
        let attempt: Int
    }
}

/// Sentences with numbers from the app's catalog - `Text(app:)` has no placeholders.
enum Wording {
    static func phrase(_ lookupKey: String, _ values: CVarArg...) -> String {
        let template = String(localized: String.LocalizationValue(lookupKey), bundle: .main)
        return String(format: template, locale: .current, arguments: values)
    }
}

extension View {
    /// The screen stays on while reading - nothing on the Mac.
    fileprivate func keepAwake() -> some View {
        #if os(iOS)
            return onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #else
            return self
        #endif
    }

    fileprivate func statusStrip(hidden: Bool) -> some View {
        #if os(iOS)
            return statusBarHidden(hidden)
        #else
            return self
        #endif
    }
}
