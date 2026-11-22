import BackgroundTasks
import Bedrock
import Features
import UIKit

/// The background fetch for new podcast episodes: a `BGAppRefreshTask` that iOS
/// grants whenever it wants.
///
/// **What "whenever it wants" means:** `earliestBeginDate` is a lower bound, not an appointment.
/// iOS learns when someone uses the app and wakes it beforehand - with daily use
/// several times a day, for an app that lies unused for weeks hardly at all. Hence the core
/// also checks on every return to the foreground.
///
/// **Scheduling happens on moving to the background and after every run** - and only while
/// the master switch is on. An app that should report nothing does not ask to be woken.
enum EpisodeRefresher {

    static let identifier = "dev.ms-solutions.akari.folgen"
    /// At the earliest one hour after the last run - iOS rarely grants more often anyway.
    static let spacing: TimeInterval = 60 * 60

    /// Must be in place before the end of `didFinishLaunching`, otherwise iOS discards the task.
    ///
    /// With `using: .main` iOS calls the handler on the main queue - the compiler
    /// does not know that, and `BGTask` is not `Sendable`. The task therefore crosses
    /// as `nonisolated(unsafe)` into `assumeIsolated`: it never leaves the main queue.
    static func report() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            nonisolated(unsafe) let mainTask = task
            MainActor.assumeIsolated { execute(mainTask) }
        }
    }

    @MainActor
    static func plane() {
        guard CloudAnchor.core?.context.notifications.to == true else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: spacing)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Diagnostics.deficiency(
                "Episode alarm: not scheduled — \(error.localizedDescription)", since: nil,
                area: "Notifications")
        }
    }

    /// Schedules the next run first: if this one runs out of time, the next is already set.
    @MainActor
    private static func execute(_ task: BGAppRefreshTask) {
        plane()
        guard let core = CloudAnchor.core else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            await core.checkEpisodes()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}
