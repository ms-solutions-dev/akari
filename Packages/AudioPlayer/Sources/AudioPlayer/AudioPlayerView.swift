import DesignSystem
import SourcesKit
import SwiftUI

/// The player's sheet: cover, name, chapter, slider within the chapter, the five
/// buttons, below them speed, sleep and chapter. The player itself belongs to the
/// shell - the sheet only shows it, and when it closes the player keeps going.
///
/// On iPad (wide size class) the core - cover, name, chapter, slider,
/// buttons, bottom row - is capped at ``coreWidth`` and centered, the cover
/// larger; the header with chevron and ... stays full width. Without a cap the sheet was
/// the iPhone sheet at 1,032 x 1,376 pt: a 1,000 pt slider, four symbols 600 pt
/// apart, the lower half empty (Podcasts and
/// Books cap at about 560 pt). Full screen, not a
/// form sheet - the sheet rises from the mini player and closes with the drag
/// down. Nothing changes in the narrow size class.
public struct AudioPlayerView: View {

    /// The cap of the core on iPad - slightly more than Podcasts, so the slider
    /// of a ten-hour chapter still has travel.
    static let coreWidth: CGFloat = 600
    /// The cover: on iPad a 520 pt frame (408 image after margins), otherwise 420 (308).
    static func coverCap(wide: Bool, large: Bool) -> CGFloat {
        if large { return 240 }
        return wide ? 520 : 420
    }

    let player: Player
    @State private var chapterOpen = false
    @State private var speedOpen = false
    @State private var dragging: Double?
    @State private var clock = Date()
    static let dragToClose: CGFloat = 120
    /// The color of the cover in the room - computed once per image, not
    /// on every second tick of the player.
    @State private var glowColor: AdaptiveColor?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePlayer) private var closeAction
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var calm
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var width

    public init(player: Player) {
        self.player = player
    }

    /// As a shell layer the shell's action closes, as a sheet `dismiss`.
    private func close() {
        if let closeAction { closeAction() } else { dismiss() }
    }

    private var audiobook: Audiobook? { player.audiobook }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let audiobook {
                ScrollView {
                    VStack(spacing: 22) {
                        cover
                            .padding(.top, 8)
                        VStack(spacing: 4) {
                            Text(verbatim: audiobook.name)
                                .font(Typography.title(.title2))
                                .multilineTextAlignment(.center)
                            if let subline = audiobook.subline {
                                Text(verbatim: subline)
                                    .font(.subheadline)
                                    .foregroundStyle(ColorTheme.muted.color)
                            }
                            if let narrator = audiobook.narrator {
                                Text(verbatim: Wording.phrase("player.readBy", narrator))
                                    .font(.caption)
                                    .foregroundStyle(ColorTheme.muted.color)
                            }
                        }
                        .padding(.horizontal, 24)
                        chapterRow
                        slider
                        buttons
                        if let failure = player.failure {
                            // The audio dropped (network gone): say why, and that Play
                            // retries - instead of a Play button that taps into the void.
                            Label {
                                Text(appKey: failure)
                            } icon: {
                                Image(systemName: "wifi.exclamationmark")
                            }
                            .font(.footnote)
                            .foregroundStyle(ColorTheme.muted.color)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .lineLimit(3)
                        }
                        bottom
                    }
                    .padding(.bottom, 24)
                    .frame(maxWidth: width == .regular ? AudioPlayerView.coreWidth : .infinity)
                    .frame(maxWidth: .infinity)
                }
                // The close drag and the list's rubber band ran simultaneously -
                // two movements, two spring-backs, it stuttered. If
                // the content fits, nothing bounces; once the drag has begun, nothing scrolls
                // any more (``CloseGesture``).
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            } else {
                EmptyState(glyph: "headphones", title: Text(app: "player.empty"))
            }
        }
        .paper()
        .sheet(isPresented: $chapterOpen) {
            ChapterSheet(player: player)
                .theme(theme)
        }
        .task(id: player.sleepEnd) {
            // The remaining sleep time counts down visibly - only if one is running:
            // the per-second tick otherwise made the whole sheet recompute every second.
            guard player.sleepEnd != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                clock = Date()
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                close()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(app: "action.close"))
            Spacer()
            Text(app: "player.title")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ColorTheme.muted.color)
            Spacer()
            @Bindable var presets = player.presets
            Menu {
                Picker(selection: $presets.jumpForward) {
                    ForEach(PlayDefaults.jumpDistances, id: \.self) { s in
                        Text(verbatim: Wording.phrase("player.seconds", s)).tag(s)
                    }
                } label: {
                    Label(app: "player.jumpForward", systemImage: "goforward")
                }
                .pickerStyle(.menu)
                Picker(selection: $presets.jumpBack) {
                    ForEach(PlayDefaults.jumpDistances, id: \.self) { s in
                        Text(verbatim: Wording.phrase("player.seconds", s)).tag(s)
                    }
                } label: {
                    Label(app: "player.jumpBack", systemImage: "gobackward")
                }
                .pickerStyle(.menu)
                if let toSeries = audiobook?.toSeries {
                    Divider()
                    Button {
                        close()
                        toSeries()
                    } label: {
                        Label(app: "menu.series", systemImage: "books.vertical")
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
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.fill.color)
            if let image = player.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(ColorTheme.muted.color)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The shadow on a shape instead of the image: Core Animation computes it from the
        // outline instead of sampling the whole cover every frame.
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.fill.color)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
        .scaleEffect(player.running ? 1 : 0.94)
        .animation(Motion.soft(calm), value: player.running)
        .background {
            // The cover's light behind the player, breathing.
            Glow(glowColor)
                .padding(-90)
        }
        .task(id: player.image.map { ObjectIdentifier($0) }) {
            // Off the main actor - the player cover is 1,800 px - and soft, because the
            // cover arrives after opening.
            let image = player.image
            let color = await Task.detached(priority: .utility) { image.flatMap(CoverColor.glow) }.value
            // No image, no light; a gray cover glows in the accent color.
            glowColor = image == nil ? nil : (color ?? theme.accent)
        }
        .padding(.horizontal, 56)
        // Half the size at accessibility sizes: otherwise the cover pushed the
        // buttons below the edge, and whoever needs AX3 is not looking for the picture.
        .frame(
            maxWidth: AudioPlayerView.coverCap(
                wide: width == .regular, large: typeSize.isAccessibilitySize))
    }

    /// Chapter row and slider as views of their own: they read the player's time (twice
    /// a second). If they read it here, the whole sheet including cover and glow would recompute -
    /// even during the close drag.
    private var chapterRow: some View {
        ChapterRow(player: player, unresolved: $chapterOpen)
    }

    private var slider: some View {
        SliderRow(player: player, dragging: $dragging)
    }

    private var buttons: some View {
        HStack(spacing: 18) {
            button("backward.end", "player.previousChapter", size: 22) { player.previousChapter() }
            button("gobackward.\(player.presets.jumpBack)", "player.jumpBack", size: 30) {
                player.jump(around: -TimeInterval(player.presets.jumpBack))
            }
            Button {
                player.switchTo()
                Haptics.selection()
            } label: {
                ZStack {
                    Circle()
                        .fill(theme.accent.color)
                        .frame(width: 76, height: 76)
                    if player.buffering && player.running {
                        ProgressView()
                            .tint(theme.buttonText.color)
                    } else {
                        Image(systemName: player.running ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(theme.buttonText.color)
                            .offset(x: player.running ? 0 : 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(app: player.running ? "player.pause" : "player.play"))
            button("goforward.\(player.presets.jumpForward)", "player.jumpForward", size: 30) {
                player.jump(around: TimeInterval(player.presets.jumpForward))
            }
            button("forward.end", "player.nextChapter", size: 22) { player.nextChapter() }
        }
        .padding(.top, 4)
    }

    private func button(
        _ glyph: String, _ lookupKey: String, size: CGFloat, _ action: @escaping () -> Void
    )
        -> some View
    {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: size, weight: .medium))
                .frame(width: TapTarget.atLeast + 8, height: TapTarget.atLeast + 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(appKey: lookupKey))
    }

    private var bottom: some View {
        HStack(spacing: 0) {
            // Speed: tapping opens the steps, holding jumps to 1x. One button
            // with a dialog, not a menu: a menu with an empty `primaryAction` did
            // nothing on tap and opened on hold - together with the jump to 1x.
            Button {
                speedOpen = true
            } label: {
                Text(verbatim: tempoText(player.tempo))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: .infinity, minHeight: TapTarget.atLeast)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    player.held = true
                    Haptics.selection()
                }
            )
            .onChange(of: player.running) { _, _ in player.held = false }
            .accessibilityLabel(Text(app: "player.tempo"))
            .accessibilityValue(Text(verbatim: tempoText(player.tempo)))
            .confirmationDialog(
                Text(app: "player.tempo"), isPresented: $speedOpen, titleVisibility: .visible
            ) {
                ForEach(PlayRules.tempos, id: \.self) { t in
                    Button {
                        player.set(tempo: t)
                    } label: {
                        Text(verbatim: tempoText(t) + (t == player.presets.tempo ? " ✓" : ""))
                    }
                }
            }
            Menu {
                ForEach(SleepTimer.selection, id: \.self) { choice in
                    Button {
                        player.set(sleep: choice)
                    } label: {
                        Text(verbatim: sleepText(choice))
                    }
                }
                if player.sleep != nil {
                    Divider()
                    Button(role: .destructive) {
                        player.set(sleep: nil)
                    } label: {
                        Text(app: "player.sleepOff")
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: player.sleep == nil ? "moon" : "moon.fill")
                        .font(.body.weight(.semibold))
                    if let sleep = player.sleep {
                        Text(verbatim: sleepRemaining(sleep))
                            .font(.caption2.monospacedDigit())
                    }
                }
                .frame(maxWidth: .infinity, minHeight: TapTarget.atLeast)
            }
            .accessibilityLabel(Text(app: "player.sleep"))
            AirPlayButton(color: theme.accent.color)
                .frame(maxWidth: .infinity, minHeight: TapTarget.atLeast)
                .accessibilityLabel(Text(app: "player.airplay"))
            Button {
                chapterOpen = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: TapTarget.atLeast)
            }
            .accessibilityLabel(Text(app: "player.chapter"))
        }
        .foregroundStyle(theme.accent.color)
        .padding(.horizontal, 28)
    }

    private func tempoText(_ t: Double) -> String {
        t.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func sleepText(_ choice: SleepTimer) -> String {
        switch choice {
        case .minutes(let n): Wording.phrase("player.minutes", n)
        case .chapterEnd: String(localized: "player.chapterEnd", bundle: .main)
        }
    }

    private func sleepRemaining(_ choice: SleepTimer) -> String {
        switch choice {
        case .minutes:
            PlayRules.clock(max(player.sleepEnd?.timeIntervalSince(clock) ?? 0, 0))
        case .chapterEnd:
            String(localized: "player.chapterEnd.short", bundle: .main)
        }
    }
}

/// The chapters as a list, the current one marked; a tap jumps there.
struct ChapterSheet: View {

    let player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                List {
                    if let audiobook = player.audiobook {
                        ForEach(Array(audiobook.volume.chapter.enumerated()), id: \.offset) { i, chapter in
                            let current = i == player.chapterIndex
                            Button {
                                player.jump(to: chapter.startTime)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(verbatim: chapter.name)
                                        .font(current ? .body.weight(.semibold) : .body)
                                        .lineLimit(2)
                                    Spacer()
                                    Text(verbatim: PlayRules.clock(chapter.end - chapter.startTime))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minHeight: TapTarget.atLeast)
                            }
                            .foregroundStyle(current ? Color.accentColor : Color.primary)
                            .id(i)
                            .accessibilityAddTraits(current ? .isSelected : [])
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear { if let i = player.chapterIndex { reader.scrollTo(i, anchor: .center) } }
            }
            .paper()
            .navigationTitle(Text(app: "player.chapter"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(app: "action.done")
                    }
                }
            }
        }
    }
}

/// The mini player in the bar (Books pattern): cover, name, chapter,
/// play/pause and the skip forward. A tap on the rest opens the sheet.
public struct MiniPlayerView: View {

    let player: Player
    /// Whether it is playing - passed as a value, not only read from the player: the
    /// accessory above the bar is a system window, and there the change
    /// to pause did not arrive - the skip button stayed, the cross was missing.
    /// With the value the shell rebuilds the mini player on every change.
    let running: Bool
    let open: () -> Void
    let close: () -> Void
    @Environment(\.theme) private var theme
    @State private var breadcrumb: CGFloat = 0

    public init(player: Player, running: Bool, open: @escaping () -> Void, close: @escaping () -> Void) {
        self.player = player
        self.running = running
        self.open = open
        self.close = close
    }

    public var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.fill.color)
                        if let image = player.image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "headphones")
                                .foregroundStyle(ColorTheme.muted.color)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        // The mini player stays one line high; long German titles
                        // shrink a little before being truncated.
                        Text(verbatim: player.audiobook?.name ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Group {
                            if let failure = player.failure {
                                Text(appKey: failure)
                            } else {
                                Text(verbatim: player.chapter?.name ?? player.audiobook?.subline ?? "")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(ColorTheme.muted.color)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                player.switchTo()
            } label: {
                Image(systemName: running ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(app: running ? "player.pause" : "player.play"))
            // While playing, the skip stands on the right; paused, the cross - whoever stopped
            // wants to continue or leave, not skip 30 seconds ("how do I get the pill
            // away"). Swiping and holding stay alongside.
            if running {
                Button {
                    player.jump(around: TimeInterval(player.presets.jumpForward))
                } label: {
                    Image(systemName: "goforward.\(player.presets.jumpForward)")
                        .font(.title3.weight(.medium))
                        .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(app: "player.jumpForward"))
            } else {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: TapTarget.atLeast, height: TapTarget.atLeast)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(app: "player.close"))
            }
        }
        .padding(.horizontal, 12)
        .foregroundStyle(ColorTheme.typography.color)
        .offset(y: breadcrumb)
        .opacity(1 - Double(breadcrumb / 80))
        // Swiping down closes the player ("cannot get rid of the
        // display") - the state goes out first. A long press offers
        // the same as a menu.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in breadcrumb = max(value.translation.height, 0) }
                .onEnded { value in
                    if breadcrumb > 40 || value.predictedEndTranslation.height > 120 {
                        close()
                    }
                    breadcrumb = 0
                }
        )
        .contextMenu {
            Button(role: .destructive, action: close) {
                Label(app: "player.close", systemImage: "xmark.circle")
            }
        }
        .accessibilityAction(named: Text(app: "player.close"), close)
    }
}

/// Sentences with numbers from the app's catalog - `Text(app:)` has no placeholders.
enum Wording {
    static func phrase(_ lookupKey: String, _ values: CVarArg...) -> String {
        let template = String(localized: String.LocalizationValue(lookupKey), bundle: .main)
        return String(format: template, locale: .current, arguments: values)
    }
}

/// The drag down that closes the player - as in Apple Music: the whole layer follows
/// the finger, paper included, and the app is visible below. On release it exits with
/// the finger's momentum in **one** motion; only then does it vanish.
///
/// **Why**: as a full-screen sheet the drag only moved the content over the stationary paper,
/// and on release iOS began the dismissal as a new animation from standstill - first a stop, then
/// departure. The player is therefore a layer of the shell, no longer a sheet.
///
/// A modifier of its own so the drag only recomputes it: the content is
/// opaque to SwiftUI, only the offset changes. Scroll lock and light enter as environment
/// and flip once. The drag engages softly after 10 pt, without a jump.
public struct CloseGesture: ViewModifier {

    /// Removes the layer - without an animation of its own, it has already left the screen.
    let closed: () -> Void
    @State private var breadcrumb: CGFloat = 0
    @State private var height: CGFloat = 900
    @State private var slidesOff = false
    /// The content needs the drag itself (``CloseGestureLocked``).
    @State private var locked = false
    @Environment(\.accessibilityReduceMotion) private var calm
    /// Held from outside (app in background) - the drag adds to it, does not replace it.
    @Environment(\.lightHeld) private var lightIsHeld

    private static let threshold: CGFloat = 10

    public init(closed: @escaping () -> Void) {
        self.closed = closed
    }

    public func body(content: Content) -> some View {
        content
            .scrollDisabled(breadcrumb > 0)
            .onPreferenceChange(CloseGestureLocked.self) { locked = $0 }
            .environment(\.lightHeld, lightIsHeld || breadcrumb > 0)
            // The whole way to below the edge: paper and light extend past the safe
            // area - with the height alone a strip stayed at the end of the ride.
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom + 120
            } action: {
                height = $0
            }
            #if DEBUG
                // `AKARI_ZUGPROBE=<pt>`: holds the drag for a screenshot - the
                // simulator without a finger otherwise does not show what lies underneath while dragging.
                .task {
                    guard let value = ProcessInfo.processInfo.environment["AKARI_ZUGPROBE"],
                        let pt = Double(value)
                    else { return }
                    try? await Task.sleep(for: .seconds(3))
                    breadcrumb = pt
                }
            #endif
            // The edge of the layer: player and app carry the same paper, without a shadow no
            // border would be visible while dragging. A gradient instead of `.shadow` - no blur pass.
            .background(alignment: .top) {
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.14)], startPoint: .top, endPoint: .bottom
                )
                .frame(height: 28)
                .offset(y: -28)
                .ignoresSafeArea()
                .opacity(breadcrumb > 0 ? 1 : 0)
            }
            // Only move, do not fade: an opacity on the whole layer made it recomposite
            // shadow, large cover and light every frame.
            .offset(y: breadcrumb)
            .simultaneousGesture(
                DragGesture(minimumDistance: CloseGesture.threshold, coordinateSpace: .global)
                    .onChanged { value in
                        guard !slidesOff, !locked else { return }
                        let dx = abs(value.translation.width)
                        let dy = value.translation.height
                        guard breadcrumb > 0 || (dy > 0 && dy > dx * 1.5) else { return }
                        breadcrumb = max(dy - CloseGesture.threshold, 0)
                    }
                    .onEnded { value in
                        guard !slidesOff else { return }
                        // Only an accepted drag closes - a jolt on the slider does not.
                        if breadcrumb >= AudioPlayerView.dragToClose
                            || (breadcrumb > 0 && value.predictedEndTranslation.height > 400)
                        {
                            slideOff(tempo: value.velocity.height)
                        } else {
                            withAnimation(Motion.fast(calm)) { breadcrumb = 0 }
                        }
                    }
            )
    }

    /// Out with the finger's momentum: `initialVelocity` is relative to the remaining distance.
    private func slideOff(tempo: CGFloat) {
        slidesOff = true
        guard !calm else {
            closed()
            return
        }
        let remainder = max(height - breadcrumb, 1)
        let momentum = max(tempo, 0) / remainder
        withAnimation(.interpolatingSpring(duration: 0.32, bounce: 0, initialVelocity: momentum)) {
            breadcrumb = height
        } completion: {
            closed()
        }
    }
}

/// How the player closes when it is not a presentation - the shell puts it as a
/// layer over the app (``CloseGesture``), where `dismiss` does nothing. Without a value `dismiss` applies.
private struct ClosePlayerKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    public var closePlayer: (@MainActor () -> Void)? {
        get { self[ClosePlayerKey.self] }
        set { self[ClosePlayerKey.self] = newValue }
    }
}

/// The chapter row above the slider - "Chapter 3 / 24 - name", tappable.
private struct ChapterRow: View {
    let player: Player
    @Binding var unresolved: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var audiobook: Audiobook? { player.audiobook }

    var body: some View {
        Button {
            unresolved = true
        } label: {
            HStack(spacing: 6) {
                if let i = player.chapterIndex, let audiobook {
                    // One text, not three: "Chapter 1 / 3 - name" may wrap at large
                    // font sizes instead of the name becoming "Chapt...".
                    let counter = Wording.phrase("player.chapterOf", i + 1, audiobook.volume.chapter.count)
                    if let name = player.chapter?.name {
                        Text("\(Text(verbatim: counter).fontWeight(.semibold)) · \(Text(verbatim: name))")
                            .font(.footnote.monospacedDigit())
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(verbatim: counter)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                    }
                } else {
                    Text(app: "player.chapter")
                        .font(.footnote.weight(.semibold))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(ColorTheme.muted.color)
            .frame(minHeight: TapTarget.atLeast)
        }
        .buttonStyle(.plain)
        .disabled(audiobook?.volume.chapter.isEmpty ?? true)
    }

}

/// The slider with the times - the only place on the sheet that recomputes twice a
/// second.
private struct SliderRow: View {
    let player: Player
    @Binding var dragging: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The slider runs within the chapter, not the book - ten hours on 300 points
    /// would be two minutes per point.
    var body: some View {
        let startTime = player.chapter?.startTime ?? 0
        let end = player.chapter?.end ?? max(player.duration, 1)
        let length = max(end - startTime, 1)
        let layout = dragging ?? (player.time - startTime)
        return VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(max(layout, 0), length) },
                    set: { dragging = $0 }), in: 0...length,
                onEditingChanged: { active in
                    if !active, let target = dragging {
                        player.jump(to: startTime + target)
                        dragging = nil
                    }
                }
            )
            .frame(minHeight: TapTarget.atLeast)
            .accessibilityLabel(Text(app: "player.location"))
            // At accessibility sizes "10 h 30 min left" slides below the
            // times - three in one line made "-3:28:06" wrap.
            let large = typeSize.isAccessibilitySize
            VStack(spacing: 2) {
                HStack {
                    Text(verbatim: PlayRules.clock(layout))
                    Spacer()
                    if !large { Text(verbatim: Wording.phrase("player.remaining", remainingText)); Spacer() }
                    Text(verbatim: "−" + PlayRules.clock(length - layout))
                }
                .lineLimit(1)
                if large { Text(verbatim: Wording.phrase("player.remaining", remainingText)) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(ColorTheme.muted.color)
        }
        .padding(.horizontal, 28)
    }

    /// "9 h 12 min left" - at the speed that is currently running.
    private var remainingText: String {
        let remainder = max(player.duration - player.time, 0) / max(player.tempo, 0.1)
        let h = Int(remainder) / 3600
        let m = (Int(remainder) % 3600) / 60
        return h > 0 ? Wording.phrase("player.hoursMinutes", h, m) : Wording.phrase("player.minutes", m)
    }

}
