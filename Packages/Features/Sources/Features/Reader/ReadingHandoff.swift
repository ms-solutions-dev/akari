import Foundation
import SourcesKit
import SwiftUI

/// Handoff "Read": while a reader or the player is open, the title is published as an
/// `NSUserActivity`, so the iPad shows in the Dock what the iPhone is reading and a tap
/// opens the same title there in the reader.
///
/// **The link is the whole message:** `akari://lesen/<provider>/<server>/<id>` in
/// `userInfo`, the same route as a deep link from the widget. No `webpageURL`, because
/// that requires http(s) and throws for a custom scheme. The target device opens the
/// link in the active profile; if the account is missing there, the shell says so
/// (`deeplink.unbekannt`) instead of silently doing nothing.
enum ReadingHandoff {

    /// The activity type. It must also be listed in `NSUserActivityTypes` in Info.plist,
    /// otherwise the target device does not accept the activity.
    static let kind = "dev.ms-solutions.akari.lesen"
    static let linkKey = "link"

    /// Fills an activity with the title: name as headline, the link as content.
    static func fill(_ activity: NSUserActivity, with title: Title) {
        activity.title = title.name
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.requiredUserInfoKeys = [linkKey]
        activity.addUserInfoEntries(from: [linkKey: Deeplink.read(title.identifier).url.absoluteString]
        )
    }

    /// The link from an accepted activity, or `nil` if there is none or it is not a
    /// deep link.
    static func link(from activity: NSUserActivity) -> Deeplink? {
        guard activity.activityType == kind, let text = activity.userInfo?[linkKey] as? String,
            let url = URL(string: text)
        else { return nil }
        return Deeplink(url)
    }
}

extension View {

    /// Publishes the title as a Handoff activity while the view is on screen.
    func readingHandoff(_ title: Title) -> some View {
        userActivity(ReadingHandoff.kind, element: title) { title, activity in
            ReadingHandoff.fill(activity, with: title)
        }
    }
}
