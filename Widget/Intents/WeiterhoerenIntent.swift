import AppIntents
import Foundation
import WidgetBridge

/// The play/pause button of the "Continue listening" widget.
///
/// **This file lives in the app and the extension** (`project.yml`: `Widget/Intents` in
/// both targets) - that is what WidgetKit wants: the extension needs the type for
/// `Button(intent:)`, and the system looks it up in the app when executing. Because the
/// intent is an `AudioPlaybackIntent`, ``perform()`` runs **in the app's process**,
/// not the extension's - even when the app is in the background; if it is
/// not started, the system starts it in the background for this (Apple, "Adding
/// interactivity to widgets and Live Activities": "if the intent conforms to
/// `AudioPlaybackIntent` ... the system performs the app intent in the app's process").
/// `openAppWhenRun` stays `false`: pause and resume should not bring the app to the
/// front - as with music and podcasts. That sound can come from the background is allowed by
/// `UIBackgroundModes: audio` in `project.yml`.
///
/// **The button calls the app core** via the ``WidgetBridge/ContinueListeningSwitch``,
/// which `AkariApp.init` assigns before a frame stands: if the audiobook is in the player,
/// the core toggles; otherwise it loads it from the active profile's library (store,
/// stock, server) and plays - audio session, lock screen, state, everything as from
/// the sheet. Afterwards it writes the snapshot, and the widget shows the new
/// state. Before, the **shell** assigned the switch, and that only existed
/// with a scene: if the app was terminated (the normal case the next morning),
/// it was `nil` here, and the button did nothing.
///
/// **The last resort - `.result(opensIntent: OpenURLIntent(link))` - does not work from
/// a widget button.** Apple's description of `OpenURLIntent`: "This app intent uses your app's existing **universal link** support
/// to open the specified URL. ... You can also place the app intent on a button in an
/// interactive widget or Live Activity." Our deep link `akari://lesen/...` is
/// a custom scheme, not a universal link - and that does not apply to it; on the
/// device the button stayed mute accordingly in the failure case. The route with
/// `openAppWhenRun = true` would be out because it brought the app to the front on **every**
/// press, also on pause. As long as the app carries no associated domain,
/// the return value therefore stays an attempt without effect; what really helps in the failure
/// case is in the log (area "Player"), and the tap beside the
/// button opens the app via the `widgetURL` link as before. Both returns end
/// in the same result type (`IntentResultContainer<Never, Never, Never, Never>`, since
/// iOS 18.2), so the same `perform()` can decide this at runtime.
///
/// **The German names stay on purpose:** the type name `WeiterhoerenIntent` and its
/// parameter `kennung` are the identity of the App Intent. Shortcuts that people have
/// already saved, and the widgets on their home screens, refer to them by exactly these
/// names; renaming either would orphan them.
struct WeiterhoerenIntent: AudioPlaybackIntent {

    static let title: LocalizedStringResource = "intent.continueListening.title"
    static let description = IntentDescription("intent.continueListening.description")
    static let openAppWhenRun = false
    /// Not in Shortcuts: the button belongs to the widget, and without an identifier it would do nothing.
    static let isDiscoverable = false

    /// The title identifier as text - the core checks whether exactly this book is in the player.
    @Parameter(title: "intent.continueListening.identifier")
    /// Stays German: the parameter name belongs to the serialized identity of the intent
    /// (widget timeline, Shortcuts) and must not change.
    var kennung: String

    /// `akari://lesen/...` - from it the core loads the book if it is not in the player.
    @Parameter(title: "intent.continueListening.link")
    var link: String

    init() {}

    init(kennung: String, link: URL) {
        self.kennung = kennung
        self.link = link.absoluteString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = URL(string: link) else { return .result() }
        if let switchTo = ContinueListeningSwitch.switchTo, await switchTo(kennung, url) {
            return .result()
        }
        return .result(opensIntent: OpenURLIntent(url))
    }
}
