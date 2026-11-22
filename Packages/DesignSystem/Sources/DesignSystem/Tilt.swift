import SwiftUI

#if os(iOS) && canImport(CoreMotion)
    import CoreMotion
    import Observation
#endif

/// Books as objects: a cover tilts slightly along when
/// you drag it or tilt the iPhone (at most 6 degrees), and a highlight travels across it
/// like light over a dust jacket. Only on the hero on Start and in the detail header - not
/// in grids, not in the reader.
///
/// With "Reduce Motion" the cover stands still (tilt is dropped).
extension View {
    public func tiltable(atMost grad: Double = 6) -> some View {
        modifier(Tilt(grad: grad))
    }
}

private struct Tilt: ViewModifier {

    let grad: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lightHeld) private var isHeld
    /// Resets itself, even when the ScrollView cancels the gesture -
    /// with `@State` the cover stayed tilted after a scroll.
    @GestureState private var dragged: CGFloat = 0
    @State private var visible = false
    @State private var signedIn = false

    func body(content: Content) -> some View {
        #if os(iOS) && canImport(CoreMotion)
            let messer = TiltSensor.shared
            let nx = reduceMotion ? 0 : messer.x
            let ny = reduceMotion ? 0 : messer.y
        #else
            let nx = 0.0
            let ny = 0.0
        #endif
        // Only horizontal drags: vertical is scrolling, that should not tilt the cover.
        let x = Tilt.limited(nx + (reduceMotion ? 0 : dragged / 140))
        let y = Tilt.limited(ny)
        return
            content
            .overlay {
                // The highlight: a narrow light stripe that travels against the tilt.
                // Without a blend mode: `softLight` forced the whole cover group including the shadow into
                // a draw pass of its own on every sensor step; a
                // faint white gradient looks almost the same on covers.
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: 0.30),
                        .init(color: .white.opacity(0.12), location: 0.50),
                        .init(color: .white.opacity(0), location: 0.70),
                    ],
                    startPoint: UnitPoint(x: -0.4 - x * 0.6, y: -0.2),
                    endPoint: UnitPoint(x: 1.4 - x * 0.6, y: 1.2)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.cover, style: .continuous))
                .allowsHitTesting(false)
            }
            // Between two sensor steps (15 per second) the cover glides instead of jumping.
            .animation(reduceMotion ? nil : .linear(duration: 1.0 / 15)) {
                $0
                    .rotation3DEffect(.degrees(x * grad), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(-y * grad), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            }
            .animation(Motion.bounce(reduceMotion), value: dragged == 0)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .updating($dragged) { value, phase, _ in
                        // Only when the drag is clearly horizontal - otherwise it is scrolling.
                        if abs(value.translation.width) > abs(value.translation.height) {
                            phase = value.translation.width
                        }
                    }
            )
            #if os(iOS) && canImport(CoreMotion)
                // Only after the transition: the sensor otherwise starts in the middle of the zoom into the detail,
                // and every step turns the cover that is just flying.
                .task {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    visible = true
                    report()
                }
                .onDisappear {
                    visible = false
                    report()
                }
                .onChange(of: isHeld || reduceMotion) { report() }
            #endif
    }

    #if os(iOS) && canImport(CoreMotion)
        /// Registers with or deregisters from the sensor: it runs as long as at least one cover is visible
        /// and not paused. Counted per cover instead of a shared switch - with the
        /// switch the detail woke the sensor, and the paused hero on Start underneath
        /// put it back to sleep, depending on who came last.
        private func report() {
            let target = visible && !isHeld && !reduceMotion
            guard target != signedIn else { return }
            signedIn = target
            if target { TiltSensor.shared.begin() } else { TiltSensor.shared.end() }
        }
    #endif

    /// -1 to 1
    static func limited(_ w: Double) -> Double { min(max(w, -1), 1) }
}

#if os(iOS) && canImport(CoreMotion)
    /// The tilt of the device against the posture at appearance, -1 to 1 per axis.
    /// One sensor for all tiltable covers; it only runs while one is on screen.
    @MainActor @Observable
    final class TiltSensor {

        static let shared = TiltSensor()

        private(set) var x: Double = 0
        private(set) var y: Double = 0

        @ObservationIgnored private let manager = CMMotionManager()
        @ObservationIgnored private var user = 0
        @ObservationIgnored private var baseline: (x: Double, y: Double)?

        /// How far the tilt reaches until the cover is fully tilted (share of gravity).
        private let reach = 0.25

        func begin() {
            user += 1
            if user == 1 { launch() }
        }

        private func launch() {
            guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
            baseline = nil
            // 15 per second suffice: the animation in the cover glides between the steps.
            manager.deviceMotionUpdateInterval = 1.0 / 15
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let motion else { return }
                let gx = motion.gravity.x
                let gy = motion.gravity.y
                MainActor.assumeIsolated { self?.take(gx, gy) }
            }
        }

        /// Without setting the tilt to zero: when scrolling the sensor stops, and a
        /// tilted cover then jumped flat. This way it stays and glides back after the
        /// next start through the low-pass - the new posture is the new center.
        private func stop() {
            manager.stopDeviceMotionUpdates()
        }

        func end() {
            user = max(0, user - 1)
            if user == 0 { stop() }
        }

        private func take(_ gx: Double, _ gy: Double) {
            if baseline == nil { baseline = (gx, gy) }
            guard let baseline else { return }
            // Low-pass: the raw values jittered in the cover. At 15 instead of
            // 30 steps per second a bit more of the new value, so it follows equally fast.
            let nx = x * 0.75 + min(max((gx - baseline.x) / reach, -1), 1) * 0.25
            let ny = y * 0.75 + min(max((gy - baseline.y) / reach, -1), 1) * 0.25
            // Dead band: every new number redraws every tiltable cover. With 0.003 hand
            // tremor almost always exceeded it - 30 redraws per second while the
            // iPhone was held. 0.02 is a good tenth of a degree, invisible.
            if abs(nx - x) > 0.02 { x = nx }
            if abs(ny - y) > 0.02 { y = ny }
        }
    }
#endif
