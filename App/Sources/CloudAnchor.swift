import AccountsKit
import Bedrock
import CloudKit
import Features
import SwiftUI
import UIKit
import UserNotifications

/// The app delegate anchor for CloudKit: silent pushes and accepting a
/// share via an iCloud link that the system opens.
///
/// SwiftUI has no place of its own for `didReceiveRemoteNotification` and
/// `userDidAcceptCloudKitShareWith` - both come via the app delegate (or, with
/// scenes, via the scene delegate; SwiftUI creates it itself, hence it is
/// named via `configurationForConnecting`). The anchor hands both on to the
/// ``Features/AppCore`` that `AkariApp.init` created beforehand.
///
/// **The share link via the system** (message, AirDrop, camera on a bare
/// iCloud link) lands here without accounts - the profile comes from the zone (name, color),
/// the accounts are set up as for a new profile. The route with everything is the
/// QR code "Add device", which arrives as an `akari://` link via `onOpenURL`.
final class CloudAnchor: NSObject, UIApplicationDelegate {

    /// The core - `AkariApp.init` sets it before the delegate is called.
    @MainActor static var core: AppCore?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        UNUserNotificationCenter.current().delegate = self
        EpisodeRefresher.report()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { EpisodeRefresher.plane() }
        }
        return true
    }

    func application(
        _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        Diagnostics.deficiency(
            "Cloud: no push registration — \(error.localizedDescription)", since: nil, area: "Cloud")
    }

    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let core = CloudAnchor.core else { return .noData }
        return await core.process(push: userInfo) ? .newData : .noData
    }

    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneAnchor.self
        return configuration
    }

    func application(
        _ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        CloudAnchor.accept(metadata)
    }

    /// A share link accepted by the system: the core accepts it via the URL -
    /// as a setup code without a server, so the same route applies as for the QR code.
    @MainActor
    static func accept(_ metadata: CKShare.Metadata) {
        guard let core, let url = metadata.share.url else { return }
        let title = metadata.share[CKShare.SystemFieldKey.title] as? String
        let code = SetupCode(server: [:], person: title, sharing: url)
        Task {
            do {
                _ = try await core.acceptSharing(code)
            } catch {
                Diagnostics.deficiency(
                    "Cloud: share not accepted — \(error)", since: nil, area: "Cloud")
            }
        }
    }
}

/// Notifications about new episodes: show as a banner in the foreground too, and a
/// tap opens the notification's link via the core - on cold start it waits there until
/// the shell stands.
extension CloudAnchor: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let text = response.notification.request.content.userInfo[SystemSender.linkKey] as? String,
            let url = URL(string: text)
        else { return }
        await MainActor.run { CloudAnchor.core?.open(link: url) }
    }
}

/// The scene delegate SwiftUI gets via the app delegate - only for
/// accepting the share; windows and scenes are still built by SwiftUI.
final class SceneAnchor: NSObject, UIWindowSceneDelegate {

    /// Cold start via the share link: then the share does not arrive as a call
    /// but lies in the connection options of the first scene
    /// - the warm route below is never called on a cold start.
    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
    ) {
        if let metadata = options.cloudKitShareMetadata {
            Task { @MainActor in CloudAnchor.accept(metadata) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata)
    {
        CloudAnchor.accept(metadata)
    }
}
