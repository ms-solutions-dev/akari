import AudioPlayer
import Bedrock
import Foundation
import SourcesKit
import SourcesKitMocks

/// The widget button without a widget: `AKARI_PROBE=intent-weiterhoeren` with `-attrappen`.
///
/// The interactive button cannot be triggered in the simulator without input, but the
/// intent can: `AkariApp.init` calls the probe before the shell is up, and the probe
/// calls `WeiterhoerenIntent.perform()` exactly as the system would if the app were
/// started in the background for the button. **Twice:** immediately with an empty
/// player (load and play; after three seconds the track time must have grown) and five
/// seconds later with a running player (pause). In between, the shell comes up and must
/// adopt the running player; the mini player is the screenshot. The result is in the log.
///
/// The audiobook is the first one of the mock (`The Time Machine`, position 176 s), the same
/// one the continue-listening row and thus the widget would show.
public enum IntentProbe {

    public static let name = "intent-weiterhoeren"

    /// Whether the environment requests this probe.
    public static var requires: Bool {
        ProcessInfo.processInfo.environment["AKARI_PROBE"] == name
    }

    /// The mock audiobook as identifier and deep link, which is what the widget gives the intent.
    static var audiobook: (identifier: String, link: URL) {
        let identifier = MockShelf.audiobookshelf().extract.title[0].identifier
        return (identifier.description, Deeplink.read(identifier).url)
    }

    /// Plays the button twice.
    /// - Parameter intent: Runs the intent, `WeiterhoerenIntent(kennung:link:).perform()`;
    ///   only the app target knows the type.
    @MainActor
    public static func play(core: AppCore, intent: (String, URL) async throws -> Void) async {
        let (identifier, link) = audiobook
        let player = core.player
        Diagnostics.step("Probe \(name): button 1, player empty", since: nil, area: "Probe")
        do { try await intent(identifier, link) } catch { report("Button 1 threw: \(error)") }
        let loaded = player.audiobook?.id == identifier
        let time1 = player.time
        report(
            "Button 1: loaded \(loaded ? "✓" : "✗"), playing \(player.running ? "✓" : "✗"), position \(PlayRules.clock(time1))"
        )
        try? await Task.sleep(for: .seconds(3))
        let time2 = player.time
        report(
            "after 3 s: position \(PlayRules.clock(time2)) - track time \(time2 > time1 ? "grows ✓" : "does NOT grow ✗")"
        )
        try? await Task.sleep(for: .seconds(2))
        Diagnostics.step("Probe \(name): button 2, player running", since: nil, area: "Probe")
        do { try await intent(identifier, link) } catch { report("Button 2 threw: \(error)") }
        report(
            "Button 2: \(player.running ? "keeps playing ✗" : "paused ✓"), position \(PlayRules.clock(player.time))"
        )
        let passed = loaded && time2 > time1 && !player.running
        report("Result: \(passed ? "passed" : "NOT passed")")
    }

    private static func report(_ text: String) {
        Diagnostics.step("Probe \(name): \(text)", since: nil, area: "Probe")
    }
}
