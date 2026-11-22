import Bedrock
import DesignSystem
import SourcesKit
import SwiftUI

/// The book reader: Readium in the middle, the HUD above it, the paper of the
/// reading theme behind it - never the app's theme.
///
/// **Tap zones 25 / 50 / 25** like in the comic reader, mirrored for
/// right-to-left; "Both edges page forward" turns both edges into
/// forward. The page number is always shown at the bottom, large only with the HUD. Pulling down
/// closes, like every sheet - the drag comes from outside (`CloseGesture` of the shell, as with the
/// player). It used to live here: drag state made the whole reader including the
/// Readium view recompute every frame, and the opacity made the web view re-composite
/// every frame - the drag lagged. In flowing mode the drag belongs to the
/// text: ``CloseGestureLocked``.
public struct BookReaderView: View {

    @State private var controller: BookController
    @State private var hud = true
    /// The HUD clock: ``showHud()`` counts up, `.task(id:)` cancels the running clock
    /// and restarts. A cancelled `Task.sleep` returns IMMEDIATELY - hence
    /// the clock checks `Task.isCancelled` after sleeping. Without the check the
    /// old clock switched the HUD that was just shown off again at once: tap 1 shows,
    /// tap 2 hides (clock keeps running), tap 3 shows and cancels the clock -> off,
    /// and every further tap the same. Those were the "phantom clicks".
    @State private var hudClock = 0
    @State private var menuOpen = false
    @State private var sheet: Sheet?
    /// The term from "In the book" - its sheet only appears once "In the book" is closed.
    @State private var nextHit: Glossary.Item?
    /// The height of the term sheet on iPhone - small until the list or the map make it large.
    @State private var termDetent: PresentationDetent = .fraction(0.35)
    /// Search word for the search sheet - "All places" (up to here) or "Search in book".
    @State private var searchPreset: String?
    @State private var searchUntilHere = false
    /// The term shown last - the iPad column keeps showing it while it
    /// closes; the current hit is already `nil` at that moment.
    @State private var lastShown: Glossary.Item?
    /// The font size at the start of pinching and the one currently shown - the
    /// capsule in the middle shows it while the fingers are on the glass.
    @State private var pinchStart: Double?
    @State private var pinchDisplay: Double?
    @State private var pinchClock = 0
    /// The slider while the thumb is on it.
    @State private var dragging: Double?
    /// The window size - for the column count when only the size class changes.
    @State private var window: CGSize = .zero
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var schema
    @Environment(\.accessibilityReduceMotion) private var calm
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The profile theme (ink, terracotta, indigo, plum) - for the sheets above the book.
    @Environment(\.theme) private var profileTheme

    static let hudDuration: Duration = .seconds(3)

    private enum Sheet: String, Identifiable {
        case aa, content = "inhalt", search = "suche", inBook = "imBuch"
        var id: String { rawValue }
    }

    /// - Parameters:
    ///   - book: what is read - the file is already on the device
    ///   - style: the "Aa" sheet as a value; the default reads UserDefaults
    public init(book: ReaderBook, style: ReadingStyle? = nil) {
        _controller = State(initialValue: BookController(book: book, style: style ?? ReadingStyle()))
    }

    private var theme: ReadingStyle.ReadingTheme { controller.style.effectiveTheme(dark: schema == .dark) }
    private var book: ReaderBook { controller.book }

    private var footnoteBinding: Binding<Bool> {
        Binding<Bool>(
            get: { controller.footnote != nil },
            set: { newValue in if !newValue { controller.footnote = nil } })
    }

    /// A sheet on iPhone; when switching to the column (split view, rotation) it closes - the term
    /// stays, the column shows it.
    private var glossarySheetBinding: Binding<Glossary.Item?> {
        Binding<Glossary.Item?>(
            get: { width == .regular ? nil : controller.glossaryHits },
            set: { newValue in
                if newValue != nil || width != .regular { controller.glossaryHits = newValue }
            })
    }

    private var inspectorBinding: Binding<Bool> {
        Binding<Bool>(
            get: { width == .regular && controller.glossaryHits != nil },
            set: { newValue in if !newValue { controller.glossaryHits = nil } })
    }

    /// After a sheet closes: reset presets, show the next hit.
    private func sheetDismissed() {
        searchPreset = nil
        searchUntilHere = false
        // SwiftUI does not allow two sheets at once: only once "In the book" is gone.
        if let hit = nextHit {
            nextHit = nil
            controller.glossaryHits = hit
        }
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.paperColor.ignoresSafeArea()
                content
                hudLayer(geo.safeAreaInsets)
                if let size = pinchDisplay {
                    Label {
                        Text(verbatim: size.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "textformat.size")
                    }
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                }
                if controller.atEnd {
                    BookEndSheet(
                        book: book, theme: theme, back: { controller.back() },
                        dismiss: { dismiss() }
                    )
                    .transition(.opacity)
                }
            }
            .simultaneousGesture(pinchGesture)
        }
        .foregroundStyle(theme.inkColor)
        .preference(key: CloseGestureLocked.self, value: controller.style.reflowing)
        // Pulled down from the very top in scroll mode (``TopPull``): close.
        .onChange(of: controller.closeRequest) { _, _ in dismiss() }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .persistentSystemOverlays(hud ? .automatic : .hidden)
        .statusBarHidden(!hud)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            controller.tip = { point, size in tip(x: point.x, width: size.width) }
            controller.setAccent(light: profileTheme.accent.light, dark: profileTheme.accent.dark)
            controller.pressedKey = { pressedKey in
                switch pressedKey {
                case .arrowLeft: controller.rightToLeft ? controller.proceed() : controller.back()
                case .arrowRight: controller.rightToLeft ? controller.back() : controller.proceed()
                case .space: controller.proceed()
                default: break
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.saveState()
        }
        .task { await controller.open(dark: schema == .dark) }
        .task(id: hudClock) {
            guard hud, !menuOpen, sheet == nil else { return }
            try? await Task.sleep(for: BookReaderView.hudDuration)
            guard !Task.isCancelled, !menuOpen, sheet == nil else { return }
            withAnimation(Motion.calm(calm)) { hud = false }
        }
        .onChange(of: menuOpen) { _, unresolved in if !unresolved { hudClock += 1 } }
        .onChange(of: sheet) { _, new in if new == nil { hudClock += 1 } }
        .task(id: pinchClock) {
            guard pinchClock > 0, pinchStart == nil else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, pinchStart == nil else { return }
            withAnimation(Motion.soft(calm)) { pinchDisplay = nil }
        }
        .onChange(of: schema) { _, new in controller.adopt(dark: new == .dark) }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: { size in
            window = size
            controller.windowChanged(size: size, wide: width == .regular)
        }
        .onChange(of: width) { _, new in
            controller.windowChanged(size: window, wide: new == .regular)
        }
        .onChange(of: controller.atEnd) { _, end in if end { showHud() } }
        #if DEBUG
            // `AKARI_ZEIGEN=aa`: opens the appearance sheet six seconds after the reader appears,
            // for screenshots. Debug builds only.
            .task {
                guard ProcessInfo.processInfo.environment["AKARI_ZEIGEN"] == "aa" else { return }
                try? await Task.sleep(for: .seconds(6))
                sheet = .aa
            }
        #endif
        .sheet(
            item: $sheet,
            onDismiss: sheetDismissed
        ) { shown in
            Group {
                switch shown {
                case .aa:
                    AaSheet(
                        style: controller.style, adopt: { controller.adopt(dark: schema == .dark) },
                        glossary: controller.glossary, glossaryApply: { controller.adoptGlossary() }
                    )
                    .presentationDetents([.medium, .large])
                case .content:
                    ContentSheet(controller: controller, search: false)
                case .search:
                    ContentSheet(
                        controller: controller, search: true, preset: searchPreset,
                        untilFraction: searchUntilHere ? controller.fraction : nil)
                case .inBook:
                    // "In the book": people, places, terms, map.
                    InBookView(
                        glossary: controller.glossary, terms: controller.terms,
                        wordHere: controller.wordHere,
                        cards: controller.cards, theme: theme
                    ) { entry in
                        nextHit = entry
                        self.sheet = nil
                    }
                    .presentationDetents([.large])
                }
            }
            // In the profile theme, not fixed to ink: otherwise a green sheet lay over a book in the
            // indigo or plum theme.
            .theme(profileTheme)
        }
        .sheet(
            isPresented: footnoteBinding
        ) {
            FootnoteSheet(html: controller.footnote ?? "", theme: theme)
                .presentationDetents([.fraction(0.35), .medium])
        }
        // A tapped glossary term: term, explanation from the book, and
        // the way to all terms.
        // On iPhone a sheet that starts as small as the term and grows when the
        // list opens or the map appears - `.sheet(item:)` keeps the entry
        // until the end of the dismiss animation. As an inspector it ignored the heights and turned
        // black when dragged. On iPad the column on the right, the text stays
        // readable beside it. Both are always attached - switching the view
        // would rebuild the reader when rotating a large iPhone.
        .sheet(
            item: glossarySheetBinding,
            // Only set small after closing - in `onChange` on opening it came too late,
            // a sheet opened large for one frame.
            onDismiss: { termDetent = smallestHeight }
        ) { entry in
            termSheet(entry)
                .presentationDetents([.fraction(0.35), .medium, .large], selection: $termDetent)
        }
        .inspector(
            isPresented: inspectorBinding
        ) {
            if let entry = controller.glossaryHits ?? lastShown {
                termSheet(entry)
                    // The column on iPad cannot be swiped away: its own
                    // close button, and for VoiceOver the two-finger Z gesture.
                    .overlay(alignment: .topTrailing) {
                        Button {
                            controller.glossaryHits = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(theme.inkColor.opacity(0.7))
                                .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(app: "action.close"))
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                    }
                    .accessibilityAction(.escape) { controller.glossaryHits = nil }
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            }
        }
        .onChange(of: controller.glossaryHits) { old, new in
            if let new {
                lastShown = new
                controller.saveOpened(new)
            }
            // Another term, or the first sheet at accessibility size: straight to the smallest height.
            if new != nil, old?.id != new?.id { termDetent = smallestHeight }
            highlight(new != nil)
        }
        .accessibilityAction(named: Text(app: "reader.nextPage")) { controller.proceed() }
        .accessibilityAction(named: Text(app: "reader.previousPage")) { controller.back() }
    }

    /// The fill around the tapped term in the profile's accent color - gone with the sheet.
    private func highlight(_ to: Bool) {
        let accent = profileTheme.accent
        controller.highlightTerm(accent: to ? (theme.isDark ? accent.dark : accent.light) : nil)
    }

    /// At accessibility font sizes the sheet opens large right away - small fits nothing there.
    private var smallestHeight: PresentationDetent {
        typeSize.isAccessibilitySize ? .large : .fraction(0.35)
    }

    /// The term sheet - as a sheet on iPhone, as a column on iPad, the same content.
    private func termSheet(_ entry: Glossary.Item) -> some View {
        GlossarySheet(
            entry: entry, glossary: controller.glossary, theme: theme, terms: controller.terms,
            wordHere: controller.wordHere, chapterName: { controller.chapterName(word: $0) },
            cards: controller.cards,
            large: { withAnimation(Motion.sheet(calm)) { termDetent = .large } },
            swipe: { links in
                controller.glossaryHits = nil
                // Swiping left means forward - reversed for books that read right to left.
                if links != controller.rightToLeft { controller.proceed() } else { controller.back() }
            },
            allPeople: {
                controller.glossaryHits = nil
                // First close the term sheet, then "In the book" - SwiftUI does not show two sheets at once.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    sheet = .inBook
                }
            },
            covered: controller.style.explanationAfterTap,
            allPlaces: { e in
                controller.glossaryHits = nil
                searchPreset = e.term
                searchUntilHere = true
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    sheet = .search
                }
            }
        )
        // A new term is a new sheet - otherwise the selection of the old one would stay.
        .id(entry.id)
    }

    // MARK: - Middle

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .opens:
            VStack(spacing: 12) {
                ProgressView()
                Text(app: "book.opens")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failure:
            VStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(app: "book.notOpened")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button {
                    dismiss()
                } label: {
                    Text(app: "action.close")
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
        case .ready:
            if let navigator = controller.navigator {
                NavigatorShell(controller: navigator) {
                    guard let text = controller.takeSelection() else { return }
                    searchPreset = text
                    sheet = .search
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    Text(verbatim: Wording.phrase("book.pageOf", controller.page, controller.count)))
            }
        }
    }

    // MARK: - HUD

    private func hudLayer(_ margin: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            if hud {
                // Floating glass instead of a gray block above the
                // text; fades in calmly with a 6 pt offset.
                header
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.card))
                    .padding(.horizontal, 10)
                    .padding(.top, margin.top + 4)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            Spacer()
            if let target = controller.returnJump, !hud {
                HStack {
                    Button {
                        controller.jumpBack()
                    } label: {
                        Label {
                            Text(verbatim: Wording.phrase("book.returnJump", target.page))
                        } icon: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.leading, 16)
                    Spacer()
                }
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if hud {
                footer
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.card))
                    .padding(.horizontal, 10)
                    .padding(.bottom, max(margin.bottom, 10))
                    .transition(.opacity.combined(with: .offset(y: 6)))
            } else if controller.phase == .ready, controller.page > 0 {
                // Only once the number is right - no "Page 0 of 635" that then jumps.
                Text(verbatim: Wording.phrase("book.pageOfShort", controller.page, controller.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.inkColor.opacity(0.55))
                    .padding(.bottom, max(margin.bottom, 10))
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
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
                // German titles are long: two lines instead of truncated.
                Text(verbatim: book.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                if let subline = book.subline {
                    Text(verbatim: subline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            Button {
                sheet = .content
            } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
                    .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(app: "book.content"))
            .disabled(controller.content.isEmpty)
            if !controller.isPdf {
                Button {
                    sheet = .aa
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.body.weight(.semibold))
                        .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(app: "book.aa"))
            }
            menu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private var menu: some View {
        Menu {
            Button {
                sheet = .search
            } label: {
                Label(app: "book.search", systemImage: "magnifyingglass")
            }
            .onAppear { menuOpen = true }
            .onDisappear { menuOpen = false }
            .disabled(controller.isPdf)
            Button {
                sheet = .inBook
            } label: {
                Label(app: "book.inBook", systemImage: "person.text.rectangle")
            }
            .disabled(controller.isPdf)
            Button {
                controller.jump(fraction: 0)
            } label: {
                Label(app: "book.toStart", systemImage: "backward.end")
            }
            if let toSeries = book.toSeries {
                Button {
                    dismiss()
                    toSeries()
                } label: {
                    Label(app: "menu.series", systemImage: "books.vertical")
                }
            }
            if !book.keep {
                Button {
                    book.requestKeep()
                } label: {
                    Label(app: "book.keep", systemImage: "arrow.down.circle")
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

    /// The slider only jumps on release - as in the player; while dragging the
    /// row shows the target page (before: a jump per step, in the tunnel a request per step,
    /// and the back arrow pointed at intermediate positions).
    private var footer: some View {
        let targetPage =
            dragging.map { max(Int((Double(controller.count) * $0).rounded()), 1) } ?? controller.page
        return VStack(spacing: 4) {
            Text(verbatim: Wording.phrase("book.pageOf", targetPage, controller.count))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            HStack(spacing: 6) {
                Text(verbatim: Wording.percent(controller.fraction))
                if let left = controller.remainingInChapter {
                    Text(verbatim: "·")
                    Text(verbatim: Wording.phrase("book.remainingInChapter", left))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { dragging ?? controller.fraction },
                    set: { new in
                        dragging = new
                        showHud()
                    }), in: 0...1,
                onEditingChanged: { active in
                    if !active, let target = dragging {
                        controller.jump(fraction: target)
                        dragging = nil
                    }
                }
            )
            .frame(minHeight: TapTarget.atLeast)
            .environment(\.layoutDirection, controller.rightToLeft ? .rightToLeft : .leftToRight)
            .accessibilityLabel(Text(app: "reader.page"))
            .accessibilityValue(
                Text(verbatim: Wording.phrase("book.pageOf", controller.page, controller.count)))
            if let chapter = controller.chapter {
                Text(verbatim: chapter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Gestures

    /// Pinching as in Photos: two fingers apart - larger font, together -
    /// smaller, in tenth steps like the slider in the Aa sheet, applied on release.
    /// EPUB only: the PDF zooms itself.
    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.05)
            .onChanged { value in
                guard !controller.isPdf else { return }
                let start = pinchStart ?? controller.style.size
                if pinchStart == nil { pinchStart = start }
                let target = (start * value.magnification * 10).rounded() / 10
                let new = min(
                    max(target, ReadingStyle.sizeRange.lowerBound), ReadingStyle.sizeRange.upperBound)
                if pinchDisplay == nil {
                    withAnimation(Motion.soft(calm)) { pinchDisplay = new }
                } else {
                    pinchDisplay = new
                }
            }
            // Only re-flow on release: every tenth step under the finger made Readium
            // re-lay out the whole chapter and recount the pages, several times a second.
            // The capsule shows the size meanwhile.
            .onEnded { _ in
                if let new = pinchDisplay, new != controller.style.size {
                    controller.style.size = new
                    controller.adopt(dark: schema == .dark)
                }
                pinchStart = nil
                pinchClock += 1
            }
    }

    private func tip(x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        Diagnostics.step("HUD tap: hud was \(hud)", since: nil, area: "Reader")
        let links = x < width * 0.25
        let right = x > width * 0.75
        if links || right {
            let before = controller.style.bothMarginsForward || (controller.rightToLeft ? links : right)
            if before { controller.proceed() } else { controller.back() }
            if hud { withAnimation(Motion.calm(calm)) { hud = false } }
        } else if hud {
            withAnimation(Motion.calm(calm)) { hud = false }
        } else {
            showHud()
        }
    }

    private func showHud() {
        withAnimation(Motion.calm(calm)) { hud = true }
        hudClock += 1
    }
}

/// Sentences with numbers from the app's catalog - `Text(app:)` has no placeholders.
enum Wording {
    static func phrase(_ lookupKey: String, _ values: CVarArg...) -> String {
        let template = String(localized: String.LocalizationValue(lookupKey), bundle: .main)
        return String(format: template, locale: .current, arguments: values)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}
