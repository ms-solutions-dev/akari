import Foundation
import SwiftUI

/// The glow behind hero, detail header and player - as a **breathing
/// gradient**: a `MeshGradient` from the cover color,
/// whose inner control points drift slowly (10 and 13 s, offset against each other), so
/// the light lives without ever fidgeting. When the cover changes, the glow flows into the new
/// color.
///
/// The edge is transparent: the glow fades into the paper instead of standing as a box.
/// Text never lies on it, but on paper beside it. With "Reduce Motion" the
/// light stands still (the glow stays, because it is static). When covered or during
/// a drag ``SwiftUI/EnvironmentValues/lightHeld`` pauses it.
public struct Glow: View {

    private let color: AdaptiveColor?

    @Environment(\.colorScheme) private var schema
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lightHeld) private var isHeld
    /// Breathe only after the transition: the zoom into the detail and opening the player should
    /// have the frames to themselves; until then the light stands still.
    @State private var awake = false

    /// - Parameter color: the glow color - from ``CoverColor/glow(from:)``, for a
    ///   gray cover the theme's accent. `nil` while the cover is not there yet: then
    ///   nothing glows.
    ///
    /// **Appears once, in its color**: before, the accent stood there at 20 % until the cover,
    /// and when the cover arrived two animations ran against each other - the opacity to full in 0.28 s,
    /// the color to the cover color in 0.8 s. For a moment the accent flashed at full strength and
    /// then sank to the cover color. Now the light fades in in the right color; only a
    /// change from cover to cover flows.
    public init(_ color: AdaptiveColor?) {
        self.color = color
    }

    public var body: some View {
        ZStack {
            if let color {
                network(color)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: color)
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            awake = true
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func network(_ color: AdaptiveColor) -> some View {
        let c = color.color
        // Not full in the dark: text beside it stays above 4.5 : 1 (since the
        // transparent edge only the upper limit - text lies on the fringe).
        let core = schema == .dark ? 0.70 : 0.85
        // The edge fades into its *own* color at 0 % - `.clear` is transparent
        // black and painted gray fringes into the gradient. All eight edge points, not just the
        // corners: with opacity on the edge midpoints the glow stood as a
        // rectangle with hard edges over heading and neighboring row.
        let from = c.opacity(0)
        // 12 frames per second: the center drifts by a few percent in 10 and 13 seconds,
        // nobody sees more - every frame is a draw pass over the whole area.
        return TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion || isHeld || !awake)) {
            tick in
            let t = reduceMotion ? 0 : tick.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3, height: 3, points: Glow.points(t),
                colors: [
                    from, from, from,
                    from, c.opacity(core), from,
                    from, from, from,
                ])
        }
    }

    /// The control points at time `t`: corners fixed, edges and center on two circles
    /// with different periods - so the image only repeats after 130 s. Visibly
    /// only the center drifts; the edges carry no color anymore and only deform the mesh.
    static func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        let a = Float((t.truncatingRemainder(dividingBy: 10) / 10) * 2 * Double.pi)
        let b = Float((t.truncatingRemainder(dividingBy: 13) / 13) * 2 * Double.pi)
        return [
            SIMD2(0, 0), SIMD2(0.5 + 0.06 * sin(b), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + 0.05 * cos(a)), SIMD2(0.5 + 0.07 * cos(a), 0.5 + 0.07 * sin(b)),
            SIMD2(1, 0.5 + 0.05 * sin(a)),
            SIMD2(0, 1), SIMD2(0.5 + 0.06 * cos(b), 1), SIMD2(1, 1),
        ]
    }
}

/// Pauses the breathing of every ``Glow`` below - during a drag (closing the player)
/// and while the view is covered (reader open, app in background). Whether SwiftUI stops a
/// `TimelineView` under a full-screen sheet by itself is not guaranteed; the
/// light then simply stands still.
private struct LightHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var lightHeld: Bool {
        get { self[LightHeldKey.self] }
        set { self[LightHeldKey.self] = newValue }
    }
}
