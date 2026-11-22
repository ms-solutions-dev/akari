import Bedrock
import DesignSystem
import Features
import PerformanceDiagnostics
import SourcesKit
import SwiftUI

/// The entry point of the app.
///
/// The target stays thin: things are plugged together here, not decided. Everything visible
/// lives in `Features`, everything testable without UI in the packages below.
///
/// The appearance follows the system - hence `project.yml` contains **no**
/// `UIUserInterfaceStyle`. The four color themes arrive here as an environment value.
///
/// **The ``Features/AppCore`` is created here in `init`, not in the shell**:
/// when the system starts the app in the background for the widget's play button, there is
/// no scene and no shell - but `init` runs, and afterwards the player and
/// the switch that the `WeiterhoerenIntent` calls are in place.
///
/// **The ``CloudAnchor``** is the app delegate: silent pushes from CloudKit and
/// accepting a share link go through it to the core.
@main
struct AkariApp: App {

    @UIApplicationDelegateAdaptor(CloudAnchor.self) private var anker
    private let core: AppCore
    /// The ``DesignSystem/LanternStart`` over the shell, once per cold start.
    @State private var lanternLit: Bool

    /// In `init` and not in a `task`: whatever must be settled before the first frame
    /// (crash guard, recording, the core with the player, the widget switch)
    /// is done here.
    init() {
        AppLaunch.launch()
        // Performance diagnostics: MetricKit always, the probes only with the switch.
        // `AKARI_DIAGNOSE=1` turns them on for simulator runs.
        if ProcessInfo.processInfo.environment["AKARI_DIAGNOSE"] == "1" {
            UserDefaults.standard.set(true, forKey: Performance.recordKey)
        }
        Performance.launch()
        // The sources' sessions report every task to diagnostics - queue, connection,
        // first byte per request; without recording it discards it at once.
        NetworkObservation.set(
            NetworkObservation.Listener(
                begun: { _ in Performance.networkStarted() },
                finished: { task, metrics, failure in
                    Performance.network(task: task, metrics: metrics, failure: failure)
                }))
        // `-attrappen` as launch argument: the three mocks instead of the servers -
        // for screenshots in the simulator, without account and password.
        let mocks = ProcessInfo.processInfo.arguments.contains("-attrappen")
        core = mocks ? AppCore.mocks() : AppCore.standard()
        // The lantern for humans only: not in screenshots and UI tests (`-attrappen`,
        // `-ohneLaterne`), and not at all with "Reduce Motion" - then straight to the start page.
        let lantern =
            !mocks && !ProcessInfo.processInfo.arguments.contains("-ohneLaterne")
            && !UIAccessibility.isReduceMotionEnabled
        _lanternLit = State(initialValue: lantern)
        // While it burns, the start page's heavy work waits (``LaunchQuiet``), and its two
        // images decode off the main thread before the first frame needs them.
        if lantern {
            LanternStart.prepare()
            LaunchQuiet.hold()
        }
        core.assignContinueListeningSwitch()
        CloudAnchor.core = core
        // `AKARI_PROBE=wolke`: write the CloudKit account state to the log - whether an
        // Apple ID is signed in in the simulator, nobody tells otherwise.
        if ProcessInfo.processInfo.environment["AKARI_PROBE"] == "wolke" {
            let core = core
            Task {
                let status = await core.cloud.service?.accountStatus()
                Diagnostics.step(
                    "Probe cloud: account \(status.map { "\($0)" } ?? "no service")", since: nil,
                    area: "Cloud")
            }
        }
        if mocks, IntentProbe.requires {
            let core = core
            Task {
                await IntentProbe.play(core: core) { identifier, link in
                    _ = try await WeiterhoerenIntent(kennung: identifier, link: link).perform()
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ShellView(core: core)
                    .withBookReader()
                    .sizeClassProbe()
                if lanternLit {
                    LanternStart {
                        lanternLit = false
                        LaunchQuiet.release()
                    }
                }
            }
        }
    }
}
