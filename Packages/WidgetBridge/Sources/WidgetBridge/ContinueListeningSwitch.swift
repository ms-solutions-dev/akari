import Foundation

/// The slot through which the play/pause intent of the "Continue listening" widget reaches the
/// app's player.
///
/// **Why a slot and not a call:** the intent lives as a source file in the app
/// **and** the extension (as WidgetKit demands), and because it is an
/// `AudioPlaybackIntent`, the system runs it in the **app's process** — even
/// if the app is asleep in the background; if it is not started, the system starts
/// it in the background for that. But the intent knows neither `Features` nor the player:
/// the extension must not pull in those packages. So the app hangs its
/// action here, and the intent calls it.
///
/// **The slot is filled at app start, before any UI:** until then it was
/// filled by the shell as soon as its tabs were up — and if the system started the app in the background for
/// the button, there was no scene, no shell and no switch. The button did nothing.
/// Now the app core that `AkariApp.init` creates hangs here, and it can load and play an
/// audiobook even without a sheet.
///
/// The action receives the title id and the deep link of the audiobook and says
/// whether it could handle it: yes if this audiobook is in the player (then it
/// switched) or if it could load and play it (then it rewrote the
/// snapshot). No if loading failed — no account, server unreachable, title unknown;
/// then all that is left to the intent is to want to open the app.
public enum ContinueListeningSwitch {

    @MainActor public static var switchTo: ((_ identifier: String, _ link: URL) async -> Bool)?
}
