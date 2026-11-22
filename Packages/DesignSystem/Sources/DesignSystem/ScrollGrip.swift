import SwiftUI

extension View {
    /// A graspable scroll bar at the right edge instead of the thin one from iOS: a
    /// handle that appears while scrolling, stays briefly and can be dragged
    /// through the whole list in one drag. Only on vertical `ScrollView`s.
    public func scrubHandle() -> some View {
        modifier(ScrollGrip())
    }
}

/// The three measures that place the handle - from `ScrollGeometry`, without the margins
/// under bars: the handle only runs through the visible part.
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
    /// The margin above the content (bar, status line): `scrollTo(y:)` computes in
    /// raw content coordinates, the handle in visible ones.
    var margin: CGFloat = 0

    /// How far the content can scroll; 0 means "fits on the screen".
    var travel: CGFloat { max(content - visible, 0) }
    var fraction: CGFloat { travel > 0 ? min(max(offset / travel, 0), 1) : 0 }
}

struct ScrollGrip: ViewModifier {

    @State private var mass = ScrollMetrics()
    @State private var position = ScrollPosition()
    @State private var visible = false
    @State private var isDragging = false
    @State private var hider: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var calm

    /// The handle stays graspable even when the list is a thousand tiles long.
    private static let minimumLength: CGFloat = 48
    private static let width: CGFloat = 8
    /// A handle only pays off from one and a half screen heights - below that the thumb scrolls.
    private static let worthFrom: CGFloat = 1.5

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollMetrics.self) { g in
                ScrollMetrics(
                    offset: g.contentOffset.y + g.contentInsets.top,
                    content: g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom,
                    visible: g.containerSize.height, margin: g.contentInsets.top)
            } action: { _, new in
                mass = new
            }
            // Fade in and out on the phases, not on every scroll step: before, every
            // frame created a new fade-out task, 120 times a second.
            .onScrollPhaseChange { _, phase in
                guard !isDragging else { return }
                if phase.isScrolling {
                    hider?.cancel()
                    if !visible { visible = true }
                } else {
                    show()
                }
            }
            .overlay(alignment: .trailing) {
                if mass.content > mass.visible * ScrollGrip.worthFrom {
                    track
                }
            }
            // `AKARI_PROBE=rollen`: scrolls 900 pt after one second and leaves
            // the handle standing - the simulator without a UI knows no fingers, the
            // screenshot still shows whether handle and content fit together.
            .task {
                guard ProcessInfo.processInfo.environment["AKARI_PROBE"] == "rollen" else { return }
                try? await Task.sleep(for: .seconds(1))
                position.scrollTo(y: 900 - mass.margin)
                isDragging = true
            }
    }

    private var track: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let length = max(ScrollGrip.minimumLength, height * mass.visible / max(mass.content, 1))
            let route = max(height - length, 0)
            let top = route * mass.fraction
            Capsule()
                .fill(.secondary.opacity(isDragging ? 0.95 : 0.7))
                .overlay(Capsule().strokeBorder(.background.opacity(0.6), lineWidth: 1))
                .frame(width: ScrollGrip.width, height: length)
                .padding(.trailing, 3)
                // The handle is narrow, the target area is not - 44 pt.
                .frame(width: 44, alignment: .trailing)
                .contentShape(Rectangle())
                .offset(y: top)
                .opacity(visible || isDragging ? 1 : 0)
                .animation(Motion.short(calm), value: visible)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                Haptics.selection()
                            }
                            // The fingertip stays in the middle of the handle.
                            let target = min(
                                max((value.location.y + top - length / 2) / max(route, 1), 0), 1)
                            position.scrollTo(y: target * mass.travel - mass.margin)
                        }
                        .onEnded { _ in
                            isDragging = false
                            show()
                        }
                )
                .accessibilityHidden(true)
        }
        .frame(width: 44)
    }

    private func show() {
        visible = true
        hider?.cancel()
        hider = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, !isDragging else { return }
            visible = false
        }
    }
}
